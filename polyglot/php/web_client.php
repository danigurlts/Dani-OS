<?php
declare(strict_types=1);

final class DaniWebClient
{
    private const BLOCKED_HOSTS = ['localhost', '127.0.0.1', '::1', '0.0.0.0', '169.254.169.254'];
    private string $sessionNonce;
    private int $nodeHttpPort;
    private int $nodeWsPort;
    private ?string $projectedTelemetryPath;

    public function __construct(?string $sessionNonce = null, ?int $nodeHttpPort = null, ?int $nodeWsPort = null, ?string $projectedTelemetryPath = null)
    {
        $this->sessionNonce = $sessionNonce ?? (getenv('DANIOS_SESSION_NONCE') ?: '');
        $this->nodeHttpPort = $nodeHttpPort ?? (int)(getenv('DANIOS_HTTP_PORT') ?: 4110);
        $this->nodeWsPort   = $nodeWsPort ?? (int)(getenv('DANIOS_WS_PORT') ?: 4111);

        $envTelemetry = $projectedTelemetryPath ?? (getenv('DANIOS_EDGE_TELEMETRY_FILE') ?: null);
        if ($envTelemetry !== null && $envTelemetry !== '') {
            self::assertNoRestrictedPartitionPath($envTelemetry);
            $this->projectedTelemetryPath = $envTelemetry;
        } else {
            $this->projectedTelemetryPath = null;
        }
    }

    public static function assertNoRestrictedPartitionPath(string $candidatePath): void
    {
        if (preg_match('#[/\\\\](tier_1_active|tier_2_rolling|tier_3_baseline|\.parallel_3x3_firewall|kernel[/\\\\]seeds)#i', $candidatePath) === 1) {
            throw new RuntimeException("ZoneBoundaryViolation: PHP edge layer is barred from parallel 3x3 partition paths.");
        }
    }

    public static function assertSafeOutboundUrl(string $url): void
    {
        $parts = parse_url($url);
        if ($parts === false || empty($parts['scheme']) || empty($parts['host'])) {
            throw new RuntimeException("InvalidOutboundUrl: Malformed URL.");
        }
        $scheme = strtolower($parts['scheme']);
        if (!in_array($scheme, ['http', 'https'], true)) {
            throw new RuntimeException("DisallowedUrlScheme: Only http and https are permitted.");
        }
        $host = strtolower(trim($parts['host'], '[]'));
        if (in_array($host, self::BLOCKED_HOSTS, true) || str_starts_with($host, '127.')) {
            throw new RuntimeException("ZoneBoundaryViolation: Outbound PHP worker blocked from loopback/metadata host '{$host}'.");
        }
    }

    public function executeHttpCall(array $payload): array
    {
        $url     = (string)($payload['url'] ?? '');
        $method  = strtoupper((string)($payload['method'] ?? 'GET'));
        $headers = is_array($payload['headers'] ?? null) ? $payload['headers'] : [];
        $body    = $payload['body'] ?? null;
        $timeout = max(1, min(30, (int)($payload['timeoutSec'] ?? 10)));

        self::assertSafeOutboundUrl($url);

        $ch = curl_init($url);
        if ($ch === false) throw new RuntimeException("CurlInitFailed for '{$url}'.");

        $formattedHeaders = ['User-Agent: DaniOs-Edge-PHP/1.0'];
        foreach ($headers as $k => $v) {
            $formattedHeaders[] = is_int($k) ? (string)$v : "{$k}: {$v}";
        }

        $encodedBody = null;
        if ($body !== null) {
            if (is_array($body) || is_object($body)) {
                $encodedBody = json_encode($body, JSON_UNESCAPED_SLASHES);
                $formattedHeaders[] = 'Content-Type: application/json';
            } else {
                $encodedBody = (string)$body;
            }
        }

        $responseHeaders = [];
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST  => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_TIMEOUT        => $timeout,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_HTTPHEADER     => $formattedHeaders,
            CURLOPT_HEADERFUNCTION => static function ($curl, string $headerLine) use (&$responseHeaders): int {
                $len   = strlen($headerLine);
                $parts = explode(':', $headerLine, 2);
                if (count($parts) === 2) $responseHeaders[strtolower(trim($parts[0]))] = trim($parts[1]);
                return $len;
            },
        ]);

        if ($encodedBody !== null && !in_array($method, ['GET', 'HEAD'], true)) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $encodedBody);
        }

        $startMs    = hrtime(true);
        $rawBody    = curl_exec($ch);
        $elapsedMs  = round((hrtime(true) - $startMs) / 1_000_000, 2);
        $statusCode = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $curlErr    = curl_error($ch);
        curl_close($ch);

        if ($rawBody === false) throw new RuntimeException("HttpCallFailed ({$method} {$url}): {$curlErr}");

        $decodedJson = null;
        $contentType = $responseHeaders['content-type'] ?? '';
        if (str_contains($contentType, 'application/json') && $rawBody !== '') {
            $tmp = json_decode($rawBody, true);
            if (json_last_error() === JSON_ERROR_NONE) $decodedJson = $tmp;
        }

        return [
            'statusCode' => $statusCode,
            'ok'         => ($statusCode >= 200 && $statusCode < 300),
            'latencyMs'  => $elapsedMs,
            'headers'    => $responseHeaders,
            'json'       => $decodedJson,
            'body'       => $decodedJson === null ? $rawBody : null,
        ];
    }

    public function dispatchWebhook(array $payload): array
    {
        $url        = (string)($payload['url'] ?? '');
        $event      = (string)($payload['event'] ?? 'danios.kernel.event');
        $data       = $payload['data'] ?? [];
        $signingKey = (string)($payload['signingKey'] ?? '');
        $maxRetries = max(1, min(3, (int)($payload['retries'] ?? 2)));

        self::assertSafeOutboundUrl($url);

        $wireJson = json_encode(['source' => 'DaniOs', 'event' => $event, 'timestamp' => gmdate('c'), 'data' => $data], JSON_UNESCAPED_SLASHES);
        $headers  = ['Content-Type' => 'application/json', 'X-DaniOs-Event' => $event];
        if ($signingKey !== '') {
            $headers['X-DaniOs-Signature'] = 'sha256=' . hash_hmac('sha256', (string)$wireJson, $signingKey);
        }

        $lastResult = null;
        for ($attempt = 1; $attempt <= $maxRetries; $attempt++) {
            try {
                $lastResult = $this->executeHttpCall(['url' => $url, 'method' => 'POST', 'headers' => $headers, 'body' => $wireJson]);
                if ($lastResult['ok'] || $lastResult['statusCode'] < 500) {
                    $lastResult['attempts'] = $attempt;
                    return $lastResult;
                }
            } catch (Throwable $e) {
                $lastResult = ['ok' => false, 'error' => $e->getMessage(), 'attempts' => $attempt];
            }
            usleep($attempt * 150_000);
        }
        return $lastResult ?? ['ok' => false, 'error' => 'WebhookDeliveryExhausted'];
    }

    public function batchHttpProbe(array $targets): array
    {
        $mh      = curl_multi_init();
        $handles = [];

        foreach ($targets as $idx => $target) {
            $url = is_string($target) ? trim($target) : trim((string)($target['url'] ?? ''));
            if ($url === '') continue;

            try {
                self::assertSafeOutboundUrl($url);
            } catch (Throwable $e) {
                $handles[$idx] = ['url' => $url, 'handle' => null, 'blocked' => $e->getMessage(), 'start' => hrtime(true)];
                continue;
            }

            $ch = curl_init($url);
            curl_setopt_array($ch, [
                CURLOPT_NOBODY => true, CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT => 5, CURLOPT_CONNECTTIMEOUT => 3,
                CURLOPT_SSL_VERIFYPEER => true, CURLOPT_USERAGENT => 'DaniOs-Probe-PHP/1.0',
            ]);
            curl_multi_add_handle($mh, $ch);
            $handles[$idx] = ['url' => $url, 'handle' => $ch, 'blocked' => null, 'start' => hrtime(true)];
        }

        do {
            $status = curl_multi_exec($mh, $active);
            if ($active) curl_multi_select($mh, 0.2);
        } while ($active && $status === CURLM_OK);

        $results = [];
        foreach ($handles as $entry) {
            if ($entry['handle'] === null) {
                $results[] = ['url' => $entry['url'], 'reachable' => false, 'statusCode' => 0, 'latencyMs' => 0.0, 'error' => $entry['blocked']];
                continue;
            }
            $ch   = $entry['handle'];
            $code = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
            $err  = curl_error($ch);
            $ms   = round((hrtime(true) - $entry['start']) / 1_000_000, 2);

            $results[] = ['url' => $entry['url'], 'reachable' => ($err === '' && $code > 0), 'statusCode' => $code, 'latencyMs' => $ms, 'error' => $err !== '' ? $err : null];
            curl_multi_remove_handle($mh, $ch);
            curl_close($ch);
        }
        curl_multi_close($mh);
        return ['checkedAtUtc' => gmdate('c'), 'probes' => $results];
    }

    public function inspectPolyglotPipes(): array
    {
        $domains = [
            'Node'   => ['pipe' => 'DaniOs.Pipe.Node',   'role' => '3x3 Matrix Parser, Pruner & Desktop WebSocket Shell'],
            'PHP'    => ['pipe' => 'DaniOs.Pipe.PHP',    'role' => 'Outbound HTTP/cURL, Webhooks & Edge Diagnostics UI'],
            'Python' => ['pipe' => 'DaniOs.Pipe.Python', 'role' => 'Low-Level Syscall, Hardware & Block I/O Probes'],
        ];
        $statuses = [];
        foreach ($domains as $domain => $meta) {
            $pipeName = $meta['pipe'];
            $endpoint = PHP_OS_FAMILY === 'Windows' ? "\\\\.\\pipe\\{$pipeName}" : "/tmp/CoreFxPipe_{$pipeName}";
            $statuses[] = ['domain' => $domain, 'pipeName' => $pipeName, 'endpoint' => $endpoint, 'online' => file_exists($endpoint), 'role' => $meta['role']];
        }
        return $statuses;
    }

    public function probeNodeDesktopBridge(): array
    {
        $ch = curl_init("http://127.0.0.1:{$this->nodeHttpPort}/health");
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 2, CURLOPT_CONNECTTIMEOUT => 1]);
        $startMs = hrtime(true);
        $raw     = curl_exec($ch);
        $ms      = round((hrtime(true) - $startMs) / 1_000_000, 2);
        $code    = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $err     = curl_error($ch);
        curl_close($ch);

        if ($raw === false || $code !== 200) {
            return ['online' => false, 'httpPort' => $this->nodeHttpPort, 'wsPort' => $this->nodeWsPort, 'latencyMs' => $ms, 'error' => $err !== '' ? $err : "HTTP {$code}", 'wsClients' => 0, 'dynamicServers' => []];
        }
        $decoded = json_decode($raw, true);
        return ['online' => (bool)($decoded['ok'] ?? false), 'httpPort' => $this->nodeHttpPort, 'wsPort' => $this->nodeWsPort, 'latencyMs' => $ms, 'wsClients' => (int)($decoded['wsClients'] ?? 0), 'dynamicServers' => is_array($decoded['dynamicServers'] ?? null) ? $decoded['dynamicServers'] : []];
    }

    public function getProjectedMatrixDiagnostics(): array
    {
        return [
            'firewallPerimeter' => 'ISOLATED_KERNEL_ACL',
            'directEdgeAccess'  => 'DENIED_BY_POLICY',
            'topology'          => '3x3 (9 Nodes: .md, .yml, .json x 3 Tiers)',
            'tiers'             => [
                ['name' => 'tier_1_active',   'role' => 'Immediate Run State',   'formats' => ['journal.md', 'solutions.yml', 'state.json'], 'access' => 'Kernel Only'],
                ['name' => 'tier_2_rolling',  'role' => 'Rolling Consolidation', 'formats' => ['journal.md', 'solutions.yml', 'state.json'], 'access' => 'Kernel Only'],
                ['name' => 'tier_3_baseline', 'role' => 'Verified Invariants',   'formats' => ['journal.md', 'solutions.yml', 'state.json'], 'access' => 'Kernel Only'],
            ],
        ];
    }

    public function collectEdgeDiagnostics(array $probeTargets = []): array
    {
        return [
            'os'             => 'DaniOs',
            'layer'          => 'Zone 3 // PHP Web & Network Edge',
            'timestampUtc'   => gmdate('c'),
            'phpRuntime'     => ['version' => PHP_VERSION, 'osFamily' => PHP_OS_FAMILY, 'curlLoaded' => extension_loaded('curl'), 'ffiLoaded' => extension_loaded('ffi'), 'nonceBound' => ($this->sessionNonce !== '')],
            'polyglotPipes'  => $this->inspectPolyglotPipes(),
            'desktopBridge'  => $this->probeNodeDesktopBridge(),
            'matrixFirewall' => $this->getProjectedMatrixDiagnostics(),
            'externalProbes' => count($probeTargets) > 0 ? $this->batchHttpProbe($probeTargets) : ['checkedAtUtc' => gmdate('c'), 'probes' => []],
        ];
    }
}
