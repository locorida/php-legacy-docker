<?php
// CPU-only PHP micro benchmark (single-threaded). Pipe it into any PHP to compare environments:
//   Get-Content -Raw tests/bench.php | docker exec -i php-legacy php
//   Get-Content -Raw tests/bench.php | ssh <vm> php
$t = hrtime(true);
$a = [];
for ($i = 0; $i < 2_000_000; $i++) { $a[$i % 1000] = ($a[$i % 1000] ?? 0) + $i; }
$s = '';
for ($i = 0; $i < 300_000; $i++) { $s .= md5((string) $i); }
$words = explode('a', $s);
usort($words, fn ($x, $y) => strcmp($x, $y));
$j = json_encode(array_slice($words, 0, 50_000));
for ($i = 0; $i < 20; $i++) { $d = json_decode($j, true); }
for ($i = 0; $i < 200_000; $i++) { preg_match('/([0-9a-f]{4})-?(\d+)/', md5((string) $i), $m); }
printf("%s %.0f ms\n", PHP_VERSION, (hrtime(true) - $t) / 1e6);
