<?php
declare(strict_types=1);

/**
 * Status page: checks every service in the container.
 * Replace the contents of app/ (or point PROJECTS_DIR at your own code) to run a real app.
 *
 * ?format=json returns the same data as JSON (used by the CI smoke test).
 */

/** @return array{ok: bool, detail: string} */
function check(callable $probe): array
{
    try {
        return ['ok' => true, 'detail' => (string) $probe()];
    } catch (Throwable $e) {
        return ['ok' => false, 'detail' => $e->getMessage()];
    }
}

/** Sends one line to a plain-text TCP service and returns the first response line. */
function tcpCommand(string $host, int $port, string $command): string
{
    $socket = @fsockopen($host, $port, $errno, $errstr, 2);
    if ($socket === false) {
        throw new RuntimeException("$host:$port unreachable ($errstr)");
    }
    stream_set_timeout($socket, 2);
    if ($command !== '') {
        fwrite($socket, $command . "\r\n");
    }
    $line = fgets($socket);
    fclose($socket);
    if ($line === false) {
        throw new RuntimeException("$host:$port sent no response");
    }
    return trim($line);
}

$checks = [
    'PHP' => check(fn () => PHP_VERSION . ' (' . PHP_SAPI . ', opcache ' . (ini_get('opcache.enable') ? 'on' : 'off')
        . ', xdebug ' . (extension_loaded('xdebug') ? (getenv('XDEBUG_MODE') ?: 'off') : 'not loaded') . ')'),

    'MariaDB' => check(function () {
        $pdo = new PDO(
            sprintf('mysql:host=127.0.0.1;port=3306;dbname=%s;charset=utf8mb4', getenv('DB_NAME') ?: 'app'),
            getenv('DB_USER') ?: 'app',
            getenv('DB_PASSWORD') ?: '',
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 2],
        );
        return $pdo->query('SELECT VERSION()')->fetchColumn();
    }),

    'Redis' => check(function () {
        $redis = new Redis();
        $redis->connect('127.0.0.1', 6379, 2);
        $redis->set('status:ping', (string) time());
        return 'redis ' . $redis->info('server')['redis_version'];
    }),

    'memcached' => check(function () {
        $memcached = new Memcached();
        $memcached->addServer('127.0.0.1', 11211);
        if (!$memcached->set('status:ping', time(), 60)) {
            throw new RuntimeException($memcached->getResultMessage());
        }
        $versions = $memcached->getVersion();
        return 'memcached ' . reset($versions);
    }),

    'beanstalkd' => check(function () {
        $response = tcpCommand('127.0.0.1', 11300, 'stats');
        if (!str_starts_with($response, 'OK')) {
            throw new RuntimeException("unexpected response: $response");
        }
        return 'responding to stats';
    }),

    'Mailpit (SMTP)' => check(function () {
        $banner = tcpCommand('127.0.0.1', 1025, '');
        if (!str_starts_with($banner, '220')) {
            throw new RuntimeException("unexpected banner: $banner");
        }
        return $banner;
    }),

    'Sessions' => check(function () {
        session_start();
        $_SESSION['hits'] = ($_SESSION['hits'] ?? 0) + 1;
        return 'memcached handler, ' . $_SESSION['hits'] . ' hit(s) in this session';
    }),
];

$allOk = !in_array(false, array_column($checks, 'ok'), true);

if (($_GET['format'] ?? '') === 'json') {
    http_response_code($allOk ? 200 : 503);
    header('Content-Type: application/json');
    echo json_encode(['ok' => $allOk, 'checks' => $checks], JSON_PRETTY_PRINT);
    return;
}

http_response_code($allOk ? 200 : 503);
$e = fn (string $s): string => htmlspecialchars($s, ENT_QUOTES);
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>php-legacy-docker status</title>
  <style>
    :root { color-scheme: light dark; --ok: #1a7f37; --fail: #cf222e; }
    body { font: 15px/1.5 system-ui, sans-serif; max-width: 52rem; margin: 2rem auto; padding: 0 1rem; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: .5rem; border-bottom: 1px solid #8884; vertical-align: top; }
    .ok { color: var(--ok); font-weight: 600; }
    .fail { color: var(--fail); font-weight: 600; }
    code { font-size: .9em; }
  </style>
</head>
<body>
  <h1>php-legacy-docker</h1>
  <p class="<?= $allOk ? 'ok' : 'fail' ?>"><?= $allOk ? 'All services are up.' : 'Some services are failing.' ?></p>
  <table>
    <tr><th>Service</th><th>Status</th><th>Detail</th></tr>
    <?php foreach ($checks as $name => $result): ?>
      <tr>
        <td><?= $e($name) ?></td>
        <td class="<?= $result['ok'] ? 'ok' : 'fail' ?>"><?= $result['ok'] ? 'OK' : 'FAIL' ?></td>
        <td><code><?= $e($result['detail']) ?></code></td>
      </tr>
    <?php endforeach ?>
  </table>
  <p>Mail sent by PHP lands in Mailpit (see <code>MAIL_UI_PORT</code> in <code>.env</code>).
     JSON: <a href="?format=json"><code>?format=json</code></a></p>
</body>
</html>
