<?php
declare(strict_types=1);

class DaniOsWebClient {
    private const MAX_BATCH_TARGETS = 100;
    private const BATCH_TIMEOUT_SECONDS = 15;

    public static function assertSafeOutboundUrl(string $url, ?array $allowedHosts = null): array {
        $parts = parse_url($url);
        if ($parts === false || empty($parts['scheme']) || empty($parts['host']) || isset($parts['user']) || isset($parts['pass'])) {
            throw new RuntimeException("InvalidOutboundUrl: Malformed URL.");
        }
        $scheme = strtolower($parts['scheme']);
        if (!in_array($scheme, ['http', 'https'], true)) {
            throw new RuntimeException("DisallowedUrlScheme: Only http and https permitted.");
        }
        $host = strtolower(trim($parts['host'], '[]'));
        $port = $parts['port'] ?? ($scheme === 'https' ? 443 : 80);
        if (!is_int($port) || $port < 1 || $port > 65535) {
            throw new RuntimeException("InvalidOutboundPort: Port must be between 1 and 65535.");
        }

        if ($allowedHosts !== null) {
            $normalizedAllowedHosts = array_map(
                static fn(mixed $allowedHost): string => strtolower(trim((string)$allowedHost, '[]')),
                $allowedHosts
            );
            if (!in_array($host, $normalizedAllowedHosts, true)) {
                throw new RuntimeException("HostNotAllowed: Host is not on the strict allowlist.");
            }
        }

        if (filter_var($host, FILTER_VALIDATE_IP) !== false) {
            self::assertPublicIp($host);
            return ['host' => $host, 'resolvedIp' => $host, 'port' => $port];
        }

        $records = @dns_get_record($host, DNS_A | DNS_AAAA);
        if ($records === false || count($records) === 0) {
            throw new RuntimeException("UnresolvableHost: Hostname yielded no DNS records.");
        }

        $approvedIp = null;
        foreach ($records as $record) {
            $ip = $record['ip'] ?? $record['ipv6'] ?? null;
            if ($ip === null) {
                continue;
            }
            self::assertPublicIp($ip);
            if ($approvedIp === null) $approvedIp = $ip;
        }
        if ($approvedIp === null) {
            throw new RuntimeException("UnresolvableHost: DNS response contained no usable address records.");
        }
        return ['host' => $host, 'resolvedIp' => $approvedIp, 'port' => $port];
    }

    private static function assertPublicIp(string $ip): void {
        if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE) === false) {
            throw new RuntimeException("SSRFBlocked: Host resolved to a private or reserved IP address.");
        }
    }

    public function batchHttpProbe(array $targets, int $concurrencyLimit = 10, ?array $allowedHosts = null): array {
        if (count($targets) > self::MAX_BATCH_TARGETS) {
            throw new RuntimeException('ProbeBatchTooLarge: Too many targets.');
        }
        $concurrencyLimit = max(1, min(50, $concurrencyLimit));
        $deadline = hrtime(true) + (self::BATCH_TIMEOUT_SECONDS * 1_000_000_000);
        $results = [];

        foreach (array_chunk($targets, $concurrencyLimit) as $chunk) {
            if (hrtime(true) >= $deadline) {
                foreach ($chunk as $target) {
                    $url = is_string($target) ? trim($target) : trim((string)($target['url'] ?? ''));
                    if ($url !== '') {
                        $results[] = ['url' => $url, 'reachable' => false, 'statusCode' => 0, 'latencyMs' => 0.0, 'error' => 'BatchTimeout'];
                    }
                }
                continue;
            }

            $mh = curl_multi_init();
            if ($mh === false) throw new RuntimeException('CurlMultiInitFailed.');
            $activeHandles = [];
            try {
                foreach ($chunk as $target) {
                    $url = is_string($target) ? trim($target) : trim((string)($target['url'] ?? ''));
                    if ($url === '') continue;
                    try {
                        $targetInfo = self::assertSafeOutboundUrl($url, $allowedHosts);
                    } catch (Throwable $e) {
                        $results[] = ['url' => $url, 'reachable' => false, 'statusCode' => 0, 'latencyMs' => 0.0, 'error' => $e->getMessage()];
                        continue;
                    }

                    $ch = curl_init($url);
                    if ($ch === false) {
                        $results[] = ['url' => $url, 'reachable' => false, 'statusCode' => 0, 'latencyMs' => 0.0, 'error' => 'CurlInitFailed'];
                        continue;
                    }
                    $resolvedIpFormatted = filter_var($targetInfo['resolvedIp'], FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false
                        ? "[{$targetInfo['resolvedIp']}]" : $targetInfo['resolvedIp'];
                    $resolveHeader = "{$targetInfo['host']}:{$targetInfo['port']}:{$resolvedIpFormatted}";
                    $remainingMs = max(1, (int)(($deadline - hrtime(true)) / 1_000_000));
                    $optionsSet = curl_setopt_array($ch, [
                        CURLOPT_NOBODY => true,
                        CURLOPT_RETURNTRANSFER => true,
                        CURLOPT_FOLLOWLOCATION => false,
                        CURLOPT_RESOLVE => [$resolveHeader],
                        CURLOPT_TIMEOUT_MS => min(5000, $remainingMs),
                        CURLOPT_CONNECTTIMEOUT_MS => min(3000, $remainingMs),
                        CURLOPT_SSL_VERIFYPEER => true,
                        CURLOPT_SSL_VERIFYHOST => 2,
                        CURLOPT_USERAGENT => 'DaniOs-Probe-PHP/1.0',
                    ]);
                    if (!$optionsSet) {
                        curl_close($ch);
                        $results[] = ['url' => $url, 'reachable' => false, 'statusCode' => 0, 'latencyMs' => 0.0, 'error' => 'CurlSetOptFailed'];
                        continue;
                    }
                    if (curl_multi_add_handle($mh, $ch) !== CURLM_OK) {
                        curl_close($ch);
                        $results[] = ['url' => $url, 'reachable' => false, 'statusCode' => 0, 'latencyMs' => 0.0, 'error' => 'CurlMultiAddHandleFailed'];
                        continue;
                    }
                    $activeHandles[(int)$ch] = ['url' => $url, 'handle' => $ch, 'start' => hrtime(true)];
                }

                $active = null;
                do {
                    $status = curl_multi_exec($mh, $active);
                    if ($status !== CURLM_OK || hrtime(true) >= $deadline) break;
                    if ($active && curl_multi_select($mh, 0.2) === -1) usleep(10000);
                } while ($active && $status === CURLM_OK);

                foreach ($activeHandles as $key => $entry) {
                    $ch = $entry['handle'];
                    $timedOut = hrtime(true) >= $deadline;
                    $code = $timedOut ? 0 : (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
                    $err = $timedOut ? 'BatchTimeout' : curl_error($ch);
                    $ms = round((hrtime(true) - $entry['start']) / 1_000_000, 2);
                    $results[] = ['url' => $entry['url'], 'reachable' => ($err === '' && $code > 0), 'statusCode' => $code, 'latencyMs' => $ms, 'error' => $err !== '' ? $err : null];
                    curl_multi_remove_handle($mh, $ch);
                    curl_close($ch);
                    unset($activeHandles[$key]);
                }
            } finally {
                foreach ($activeHandles as $entry) {
                    @curl_multi_remove_handle($mh, $entry['handle']);
                    @curl_close($entry['handle']);
                }
                @curl_multi_close($mh);
            }
        }
        return ['checkedAtUtc' => gmdate('c'), 'probes' => $results];
    }
}
