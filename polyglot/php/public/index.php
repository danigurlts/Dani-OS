<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/web_client.php';

function esc(mixed $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

$client         = new DaniWebClient();
$defaultTargets = ['https://api.github.com/zen', 'https://1.1.1.1/cdn-cgi/trace'];
$rawTargetInput = is_string($_POST['targets'] ?? null) ? $_POST['targets'] : (is_string($_GET['targets'] ?? null) ? $_GET['targets'] : '');
$probeTargets   = trim($rawTargetInput) !== ''
    ? array_values(array_filter(array_map('trim', preg_split('/[\r\n,]+/', $rawTargetInput) ?: []), static fn(string $u): bool => $u !== ''))
    : $defaultTargets;

$skipProbes  = (($_GET['probes'] ?? '1') === '0');
$diagnostics = $client->collectEdgeDiagnostics($skipProbes ? [] : $probeTargets);

if (($_GET['format'] ?? '') === 'json') {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($diagnostics, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');

$pipes         = $diagnostics['polyglotPipes'];
$onlineWorkers = count(array_filter($pipes, static fn(array $p): bool => (bool)$p['online']));
$bridge        = $diagnostics['desktopBridge'];
$matrix        = $diagnostics['matrixFirewall'];
$probes        = $diagnostics['externalProbes']['probes'] ?? [];
$phpInfo       = $diagnostics['phpRuntime'];
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>DaniOs // PHP Edge Diagnostics &amp; 3×3 Perimeter Status</title>
  <style>
    :root { color-scheme: dark; --bg: #090d14; --panel: #111827; --border: #1f2937; --text: #e5e7eb; --muted: #9ca3af; --accent: #38bdf8; --ok: #10b981; --warn: #f59e0b; --err: #ef4444; }
    body { margin: 0; padding: 24px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--bg); color: var(--text); }
    header { display: flex; justify-content: space-between; align-items: center; padding-bottom: 16px; margin-bottom: 20px; border-bottom: 1px solid var(--border); }
    .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 14px; margin-bottom: 20px; }
    .card { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 16px; }
    .kpi-label { font-size: 11px; color: var(--muted); text-transform: uppercase; }
    .kpi-value { font-size: 20px; font-weight: 700; margin-top: 6px; color: var(--accent); }
    table { width: 100%; border-collapse: collapse; font-size: 12px; }
    th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border); }
    th { color: var(--muted); font-size: 11px; text-transform: uppercase; }
    .pill { padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 700; }
    .ok { background: rgba(16,185,129,.15); color: var(--ok); }
    .err { background: rgba(239,68,68,.15); color: var(--err); }
    .warn { background: rgba(245,158,11,.15); color: var(--warn); }
  </style>
</head>
<body>
  <header>
    <div><strong>⚡ DaniOs // PHP Edge Diagnostics</strong> &bull; Snapshot: <?= esc($diagnostics['timestampUtc']) ?></div>
    <a href="?format=json" style="color: var(--accent);">Raw JSON</a>
  </header>
  <section class="kpi-grid">
    <div class="card"><div class="kpi-label">Polyglot IPC Pipes</div><div class="kpi-value"><?= esc("{$onlineWorkers} / " . count($pipes)) ?> Online</div></div>
    <div class="card"><div class="kpi-label">Desktop Bridge</div><div class="kpi-value"><?= $bridge['online'] ? 'CONNECTED' : 'OFFLINE' ?></div></div>
    <div class="card"><div class="kpi-label">3×3 Firewall Partition</div><div class="kpi-value" style="color: var(--ok);">SEALED</div></div>
    <div class="card"><div class="kpi-label">PHP Runtime</div><div class="kpi-value">PHP <?= esc($phpInfo['version']) ?></div></div>
  </section>
  <section class="card">
    <h3>Zone 3 Polyglot Worker Pipes</h3>
    <table>
      <thead><tr><th>Domain</th><th>Endpoint</th><th>Status</th><th>Role</th></tr></thead>
      <tbody>
        <?php foreach ($pipes as $p): ?>
          <tr>
            <td><strong><?= esc($p['domain']) ?></strong></td>
            <td><code><?= esc($p['endpoint']) ?></code></td>
            <td><span class="pill <?= $p['online'] ? 'ok' : 'err' ?>"><?= $p['online'] ? 'LISTENING' : 'OFFLINE' ?></span></td>
            <td><?= esc($p['role']) ?></td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </section>
  <section class="card">
    <h3>Parallel 3×3 Firewall Perimeter (Zero-Traversal Isolation)</h3>
    <table>
      <thead><tr><th>Tier</th><th>Role</th><th>Nodes</th><th>Zone 3 ACL</th></tr></thead>
      <tbody>
        <?php foreach ($matrix['tiers'] as $tier): ?>
          <tr>
            <td><code><?= esc($tier['name']) ?></code></td>
            <td><?= esc($tier['role']) ?></td>
            <td><?= esc(implode(', ', $tier['formats'])) ?></td>
            <td><span class="pill warn"><?= esc($tier['access']) ?></span></td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </section>
  <section class="card">
    <h3>External Outbound HTTP Probes (SSRF-Guarded)</h3>
    <table>
      <thead><tr><th>Target URL</th><th>Reachable</th><th>Status</th><th>Latency</th><th>Notes</th></tr></thead>
      <tbody>
        <?php foreach ($probes as $probe): ?>
          <tr>
            <td><code><?= esc($probe['url']) ?></code></td>
            <td><span class="pill <?= $probe['reachable'] ? 'ok' : 'err' ?>"><?= $probe['reachable'] ? 'REACHABLE' : 'BLOCKED/DOWN' ?></span></td>
            <td><?= esc($probe['statusCode'] > 0 ? $probe['statusCode'] : '—') ?></td>
            <td><?= esc($probe['latencyMs']) ?> ms</td>
            <td><?= esc($probe['error'] ?? 'OK') ?></td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </section>
</body>
</html>
