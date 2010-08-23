use inc::Module::Install;

name 'Plack-Handler-Mongrel2';
all_from 'lib/Plack/Handler/Mongrel2.pm';
license 'artistic_2';
requires 'HTTP::Status';
requires 'JSON' => '2.00';
requires 'Parallel::Prefork';
requires 'Plack';
requires 'URI::Escape';
requires 'ZeroMQ' => '0.02';

recommends 'JSON::XS';

auto_set_repository;
author_tests 'xt';

WriteAll;