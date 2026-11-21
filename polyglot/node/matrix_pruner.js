"use strict";

const yaml = require("js-yaml");

const TIER_ORDER = ["tier_1_active", "tier_2_rolling", "tier_3_baseline"];
const JOURNAL_ENTRY_REGEX = /^- \*\*\[(.*?)\] \[(.*?)\]\*\* (.*)$/;
const MAX_TIER_PAYLOAD_BYTES = 256 * 1024;

function assertTierPayloadLimit(rawTier, tier) {
  for (const field of ["journal", "solutions", "state"]) {
    const value = rawTier[field];
    if (typeof value === "string" && Buffer.byteLength(value, "utf8") > MAX_TIER_PAYLOAD_BYTES) {
      throw new RangeError(`MatrixPayloadTooLarge: ${tier}.${field} exceeds ${MAX_TIER_PAYLOAD_BYTES} bytes.`);
    }
  }
}

function parseJournalMarkdown(rawMd) {
  const lines = (rawMd || "").split(/\r?\n/);
  const headerLines = [];
  const entries = [];
  let seenFirstEntry = false;

  for (const line of lines) {
    const match = line.match(JOURNAL_ENTRY_REGEX);
    if (match) {
      seenFirstEntry = true;
      entries.push({ timestamp: match[1], category: match[2], message: match[3], raw: line });
    } else if (!seenFirstEntry) {
      headerLines.push(line);
    }
  }

  while (headerLines.length > 0 && headerLines[headerLines.length - 1].trim() === "") {
    headerLines.pop();
  }

  return { header: headerLines.join("\n"), entries };
}

function serializeJournalMarkdown(header, entries) {
  const baseHeader = header && header.trim().length > 0 ? header.trim() : "# DaniOs Run Journal";
  const body = entries.map((e) => e.raw || `- **[${e.timestamp}] [${e.category}]]** ${e.message}`).join("\n");
  return body.length > 0 ? `${baseHeader}\n\n${body}\n` : `${baseHeader}\n`;
}

function parseSolutionsYaml(rawYml) {
  const doc = yaml.load(rawYml || "") || {};
  if (!Array.isArray(doc.baseline_playbooks)) {
    doc.baseline_playbooks = [];
  }
  return doc;
}

function deduplicatePlaybooks(playbooks) {
  const bySignature = new Map();

  for (const rule of playbooks) {
    if (!rule || !rule.signature) continue;
    const existing = bySignature.get(rule.signature);
    if (!existing) {
      bySignature.set(rule.signature, { ...rule, hit_count: Number(rule.hit_count || 1) });
    } else {
      existing.hit_count = Number(existing.hit_count || 1) + Number(rule.hit_count || 1);
      if (rule.verified_at && (!existing.verified_at || rule.verified_at > existing.verified_at)) {
        existing.remediation = rule.remediation;
        existing.verified_at = rule.verified_at;
      }
    }
  }

  return Array.from(bySignature.values());
}

function compactAndPruneMatrix(payload) {
  const maxEntries = Math.max(10, Number(payload.maxEntriesPerTier || 50));
  const incomingTiers = payload.tiers || {};

  const parsed = {};
  for (const tier of TIER_ORDER) {
    const rawTier = incomingTiers[tier] || {};
    assertTierPayloadLimit(rawTier, tier);
    parsed[tier] = {
      journal: parseJournalMarkdown(rawTier.journal),
      solutions: parseSolutionsYaml(rawTier.solutions),
      state: JSON.parse(rawTier.state || "{}")
    };
  }

  for (const tier of TIER_ORDER) {
    parsed[tier].solutions.baseline_playbooks = deduplicatePlaybooks(parsed[tier].solutions.baseline_playbooks);
  }

  const promotionThreshold = Number(
    parsed.tier_3_baseline.solutions?.kernel_invariants?.pruning_policy?.promotion_threshold_runs || 3
  );

  const t2Map = new Map(parsed.tier_2_rolling.solutions.baseline_playbooks.map((r) => [r.signature, r]));
  for (const rule of parsed.tier_1_active.solutions.baseline_playbooks) {
    if ((rule.hit_count || 1) >= 2 && !t2Map.has(rule.signature)) {
      t2Map.set(rule.signature, { ...rule, promoted_from: "tier_1_active" });
    }
  }
  parsed.tier_2_rolling.solutions.baseline_playbooks = deduplicatePlaybooks(Array.from(t2Map.values()));

  const t3Map = new Map(parsed.tier_3_baseline.solutions.baseline_playbooks.map((r) => [r.signature, r]));
  for (const rule of parsed.tier_2_rolling.solutions.baseline_playbooks) {
    if ((rule.hit_count || 1) >= promotionThreshold && !t3Map.has(rule.signature)) {
      t3Map.set(rule.signature, { ...rule, promoted_from: "tier_2_rolling" });
    }
  }
  parsed.tier_3_baseline.solutions.baseline_playbooks = deduplicatePlaybooks(Array.from(t3Map.values()));

  const stats = {
    prunedEntries: 0,
    promotedRules: parsed.tier_3_baseline.solutions.baseline_playbooks.length
  };

  const t1Entries = parsed.tier_1_active.journal.entries;
  if (t1Entries.length > maxEntries) {
    const overflowCount = t1Entries.length - maxEntries;
    const evicted = t1Entries.slice(0, overflowCount);
    const faultCount = evicted.filter((e) => e.category === "FAULT").length;
    const healCount = evicted.filter((e) => e.category === "HEALED").length;

    parsed.tier_2_rolling.journal.entries.push({
      timestamp: new Date().toISOString().replace("T", " ").slice(0, 19) + " UTC",
      category: "COMPACT",
      message: `Rolled up ${overflowCount} Tier-1 journal entries (${faultCount} faults, ${healCount} heals).`
    });

    parsed.tier_1_active.journal.entries = t1Entries.slice(overflowCount);
    stats.prunedEntries += overflowCount;
  }

  for (const tier of ["tier_2_rolling", "tier_3_baseline"]) {
    const list = parsed[tier].journal.entries;
    if (list.length > maxEntries) {
      const trim = list.length - maxEntries;
      parsed[tier].journal.entries = list.slice(trim);
      stats.prunedEntries += trim;
    }
  }

  const nowUtc = new Date().toISOString();
  const outputTiers = {};

  for (const tier of TIER_ORDER) {
    const st = parsed[tier].state;
    st.lastCompactedUtc = nowUtc;
    if (st.transientTelemetry) delete st.transientTelemetry;

    outputTiers[tier] = {
      journal: serializeJournalMarkdown(parsed[tier].journal.header, parsed[tier].journal.entries),
      solutions: yaml.dump(parsed[tier].solutions, { lineWidth: 120, noRefs: true }),
      state: JSON.stringify(st, null, 2)
    };
  }

  return { tiers: outputTiers, stats };
}

function parseStructuredStream(rawText, format = "auto") {
  const input = typeof rawText === "string" ? rawText : "";
  const firstNonWhitespace = input.search(/\S/);
  if (firstNonWhitespace === -1) return { format: "empty", records: [] };

  if (format === "json" || (format === "auto" && (input[firstNonWhitespace] === "{" || input[firstNonWhitespace] === "["))) {
    return { format: "json", data: JSON.parse(input) };
  }

  if (format === "yaml" || format === "yml") {
    return { format: "yaml", data: yaml.load(input) };
  }

  let end = input.length;
  while (end > firstNonWhitespace && /\s/u.test(input[end - 1])) end--;

  const anomalyRegex = /\b(FATAL|ERROR|EXCEPTION|PANIC|TIMEOUT|DENIED)\b/i;
  const anomalies = [];
  let totalLines = 0;
  let anomalyCount = 0;
  let lineStart = firstNonWhitespace;

  while (lineStart < end) {
    let lineEnd = input.indexOf("\n", lineStart);
    if (lineEnd === -1 || lineEnd > end) lineEnd = end;

    const line = input.slice(lineStart, lineEnd).replace(/\r$/, "").trim();
    totalLines++;
    if (anomalyRegex.test(line)) {
      anomalyCount++;
      if (anomalies.length < 100) anomalies.push({ line: totalLines, text: line });
    }

    lineStart = lineEnd + 1;
  }

  return { format: "log_stream", totalLines, anomalyCount, anomalies };
}

module.exports = { compactAndPruneMatrix, parseStructuredStream };
