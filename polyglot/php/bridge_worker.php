<?php
declare(strict_types=1);

require_once __DIR__ . '/web_client.php';

$pipeName     = getenv('DANIOS_PIPE_NAME') ?: 'DaniOs.Pipe.PHP';
$sessionNonce = getenv('DANIOS_SESSION_NONCE') ?: '';

if ($sessionNonce === '') {
    fwrite(STDERR, "[DaniOs::PHP] FATAL: Missing DANIOS_SESSION_NONCE in environment.\n");
    exit(1);
}

$webClient = new DaniOsWebClient();

function handleEnvelope(string $rawLine, string $sessionNonce, DaniOsWebClient $webClient): string
{
    $requestId = null;
    try {
        DaniWebClient::assertNoRestrictedPartitionPath($rawLine);
        $envelope  = json_decode($rawLine, true, 16, JSON_THROW_ON_ERROR);
        $requestId = $envelope['Id'] ?? null;

        if (($envelope['Nonce'] ?? '') !== $sessionNonce) {
            throw new RuntimeException("ZoneBoundaryViolation: Session nonce mismatch on PHP IPC pipe.");
        }

        $action  = (string)($envelope['Action'] ?? '');
        $payload = is_array($envelope['Payload'] ?? null) ? $envelope['Payload'] : [];

        $result = match ($action) {
            'LlmChat'         => $webClient->llmChat($payload),
            'ExecuteHttpCall' => $webClient->executeHttpCall($payload),
            'DispatchWebhook' => $webClient->dispatchWebhook($payload),
            'BatchHttpProbe'  => $webClient->batchHttpProbe($payload['targets'] ?? []),
            'Ping'            => ['pong' => true, 'phpVersion' => PHP_VERSION],
            default           => throw new RuntimeException("UnsupportedPhpAction: '{$action}'"),
        };

        return json_encode(['Id' => $requestId, 'Nonce' => $sessionNonce, 'Domain' => 'PHP', 'Ok' => true, 'Timestamp' => gmdate('c'), 'Payload' => $result], JSON_UNESCAPED_SLASHES) . "\n";
    } catch (Throwable $e) {
        return json_encode(['Id' => $requestId, 'Nonce' => $sessionNonce, 'Domain' => 'PHP', 'Ok' => false, 'Timestamp' => gmdate('c'), 'Payload' => ['error' => $e->getMessage()]], JSON_UNESCAPED_SLASHES) . "\n";
    }
}

if (PHP_OS_FAMILY === 'Windows') {
    $k32 = FFI::cdef("
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        HANDLE CreateNamedPipeA(const char* lpName, DWORD dwOpenMode, DWORD dwPipeMode, DWORD nMaxInstances, DWORD nOutBufferSize, DWORD nInBufferSize, DWORD nDefaultTimeOut, void* lpSecurityAttributes);
        BOOL ConnectNamedPipe(HANDLE hNamedPipe, void* lpOverlapped);
        BOOL ReadFile(HANDLE hFile, char* lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped);
        BOOL WriteFile(HANDLE hFile, const char* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, void* lpOverlapped);
        BOOL FlushFileBuffers(HANDLE hFile);
        BOOL DisconnectNamedPipe(HANDLE hNamedPipe);
        DWORD GetLastError();
    ", "kernel32.dll");

    $winPipePath   = "\\\\.\\pipe\\{$pipeName}";
    $invalidHandle = FFI::cast("HANDLE", -1);
    $hPipe = $k32->CreateNamedPipeA($winPipePath, 0x00000003, 0x00000000, 16, 65536, 65536, 0, null);
    if (FFI::isNull($hPipe) || $hPipe == $invalidHandle) exit(1);

    fwrite(STDOUT, "[DaniOs::PHP] Listening on {$winPipePath}\n");
    fflush(STDOUT);

    $readBuf   = FFI::new("char[65536]");
    $bytesRead = FFI::new("DWORD");
    $bytesWrit = FFI::new("DWORD");

    while (true) {
        $connected = $k32->ConnectNamedPipe($hPipe, null);
        if ($connected === 0 && $k32->GetLastError() !== 535) { usleep(10_000); continue; }
        $lineBuffer = '';
        while (true) {
            $ok = $k32->ReadFile($hPipe, $readBuf, 65535, FFI::addr($bytesRead), null);
            if ($ok === 0 || $bytesRead->cdata === 0) break;
            $lineBuffer .= FFI::string($readBuf, $bytesRead->cdata);
            while (($nlPos = strpos($lineBuffer, "\n")) !== false) {
                $line = trim(substr($lineBuffer, 0, $nlPos));
                $lineBuffer = substr($lineBuffer, $nlPos + 1);
                if ($line === '') continue;
                $response = handleEnvelope($line, $sessionNonce, $webClient);
                $k32->WriteFile($hPipe, $response, strlen($response), FFI::addr($bytesWrit), null);
                $k32->FlushFileBuffers($hPipe);
            }
        }
        $k32->DisconnectNamedPipe($hPipe);
    }
} else {
    $sockPath = "/tmp/CoreFxPipe_{$pipeName}";
    if (file_exists($sockPath)) @unlink($sockPath);
    $server = stream_socket_server("unix://{$sockPath}", $errno, $errstr);
    if ($server === false) exit(1);
    @chmod($sockPath, 0600);

    fwrite(STDOUT, "[DaniOs::PHP] Listening on {$sockPath}\n");
    fflush(STDOUT);

    register_shutdown_function(static function () use ($sockPath): void { if (file_exists($sockPath)) @unlink($sockPath); });

    while (true) {
        $conn = @stream_socket_accept($server, -1);
        if ($conn === false) continue;
        while (($line = fgets($conn)) !== false) {
            $trimmed = trim($line);
            if ($trimmed === '') continue;
            fwrite($conn, handleEnvelope($trimmed, $sessionNonce, $webClient));
            fflush($conn);
        }
        fclose($conn);
    }
}
