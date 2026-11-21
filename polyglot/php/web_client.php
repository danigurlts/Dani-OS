<?php
declare(strict_types=1);

class DaniOsWebClient {
    public static function assertNoRestrictedPartitionPath(string $raw): void {
        if (preg_match('~[/\\\\](?:tier_[123]_(?:active|rolling|baseline)|kernel[/\\\\]seeds)(?:[/\\\\]|["\\\\])~i', $raw)) {
            throw new RuntimeException('ZoneBoundaryViolation: Restricted kernel path in PHP request.');
        }
    }

    public function llmChat(array $payload): array {
        $port = filter_var($payload['port'] ?? 9931, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1, 'max_range' => 65535]]);
        $messages = $payload['messages'] ?? null;
        if ($port === false || !is_array($messages) || count($messages) < 1 || count($messages) > 64) {
            throw new RuntimeException('InvalidLlmRequest.');
        }
        foreach ($messages as $message) {
            if (!is_array($message) || !in_array($message['role'] ?? '', ['system', 'user', 'assistant'], true) || !is_string($message['content'] ?? null)) {
                throw new RuntimeException('InvalidLlmMessage.');
            }
        }
        $body = json_encode([
            'model' => (string)($payload['model'] ?? 'qwen2.5-3b'),
            'messages' => $messages,
            'temperature' => (float)($payload['temperature'] ?? 0),
            'max_tokens' => max(1, min(4096, (int)($payload['max_tokens'] ?? 96))),
            'stream' => false,
        ], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
        $curl = curl_init("http://127.0.0.1:{$port}/v1/chat/completions");
        if ($curl === false) throw new RuntimeException('LlmCurlInitFailed.');
        try {
            curl_setopt_array($curl, [
                CURLOPT_POST => true, CURLOPT_POSTFIELDS => $body, CURLOPT_RETURNTRANSFER => true,
                CURLOPT_HTTPHEADER => ['Content-Type: application/json'], CURLOPT_FOLLOWLOCATION => false,
                CURLOPT_CONNECTTIMEOUT => 3, CURLOPT_TIMEOUT => 180,
            ]);
            $response = curl_exec($curl);
            if ($response === false) throw new RuntimeException('LlmRequestFailed: ' . curl_error($curl));
            $status = (int)curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
            $decoded = json_decode($response, true, 32, JSON_THROW_ON_ERROR);
            if ($status < 200 || $status >= 300) throw new RuntimeException("LlmHttpError {$status}: " . substr($response, 0, 1000));
            return $decoded;
        } finally {
            curl_close($curl);
        }
    }

    public static function assertSafeOutboundUrl(string $url, ?array $allowedHosts = null): array {
        $parts = parse_url($url);
        if ($parts === false || empty($parts['scheme']) || empty($parts['host'])) {
            throw new RuntimeException("InvalidOutboundUrl: Malformed URL.");
        }
        $scheme = strtolower($parts['scheme']);
        if (!in_array($scheme, ['http', 'https'], true)) {
            throw new RuntimeException("DisallowedUrlScheme: Only http and https permitted.");
        }
        $host = trim($parts['host'], '[]');
        $port = $parts['port'] ?? ($scheme === 'https' ? 443 : 80);

        if ($allowedHosts !== null && !in_array(strtolower($host), array_map('strtolower', $allowedHosts), true)) {
            throw new RuntimeException("HostNotAllowed: Host '{$host}' is not on the strict allowlist.");
        }

        if (filter_var($host, FILTER_VALIDATE_IP) !== false) {
            if (filter_var($host, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE) === false) {
                throw new RuntimeException("SSRFBlocked: Literal IP '{$host}' is in a private or reserved range.");
            }
            return ['host' => $host, 'resolvedIp' => $host, 'port' => $port];
        }

        $records = @dns_get_record($host, DNS_A + DNS_AAAA);
        if ($records === false || count($records) === 0) {
            throw new RuntimeException("UnresolvableHost: Hostname '{$host}' yielded no DNS records.");
        }

        $approvedIp = null;
        foreach ($records as $record) {
            $ip = $record['ip'] ?? $record['ipv6'] ?? null;
            if (!$ip) continue;
            if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE) === false) {
                throw new RuntimeException("SSRFBlocked: Domain '{$host}' has a record resolving to private/reserved IP '{$ip}'.");
            }
            if ($approvedIp === null) { $approvedIp = $ip; }
        }
        return ['host' => $host, 'resolvedIp' => $approvedIp, 'port' => $port];
    }

    public function batchHttpProbe(array $targets, int $concurrencyLimit = 10, ?array $allowedHosts = null): array {
        $concurrencyLimit = max(1, min(50, $concurrencyLimit));
        $results = [];
        $chunks = array_chunk($targets, $concurrencyLimit);

        foreach ($chunks as $chunk) {
            $mh = curl_multi_init();
            if ($mh === false) { throw new RuntimeException("CurlMultiInitFailed."); }
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

                    $optionsSet = curl_setopt_array($ch, [
                        CURLOPT_NOBODY => true, CURLOPT_RETURNTRANSFER => true,
                        CURLOPT_FOLLOWLOCATION => false, CURLOPT_RESOLVE => [$resolveHeader],
                        CURLOPT_TIMEOUT => 5, CURLOPT_CONNECTTIMEOUT => 3,
                        CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2,
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
                    if ($status !== CURLM_OK) {
                        foreach ($activeHandles as $key => $entry) {
                            $results[] = ['url' => $entry['url'], 'reachable' => false, 'statusCode' => 0, 'latencyMs' => 0.0, 'error' => "BatchMultiExecFault: {$status}"];
                            curl_multi_remove_handle($mh, $entry['handle']);
                            curl_close($entry['handle']);
                            unset($activeHandles[$key]);
                        }
                        break;
                    }
                    if ($active && curl_multi_select($mh, 0.2) === -1) { usleep(10000); }
                } while ($active && $status === CURLM_OK);

                foreach ($activeHandles as $key => $entry) {
                    $ch = $entry['handle'];
                    $code = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
                    $err = curl_error($ch);
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
