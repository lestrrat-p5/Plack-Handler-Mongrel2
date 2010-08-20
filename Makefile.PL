use inc::Module::Install;

name 'Plack-Handler-Mongrel2';
all_from 'lib/Plack/Handler/Mongrel2.pm';
requires 'Plack';
requires 'HTTP::Status';
requires 'ZeroMQ' => '0.02';
requires 'JSON' => '2.00';

recommends 'JSON::XS';

auto_set_repository;

WriteAll;