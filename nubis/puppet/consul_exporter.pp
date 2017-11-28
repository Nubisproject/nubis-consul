$consul_exporter_version = '0.3.0'
$consul_exporter_url = "https://github.com/prometheus/consul_exporter/releases/download/v${consul_exporter_version}/consul_exporter-${consul_exporter_version}.linux-amd64.tar.gz"

notice ("Grabbing consul_exporter ${consul_exporter_version}")
staging::file { "consul_exporter.${consul_exporter_version}.tar.gz":
  source => $consul_exporter_url,
}->
staging::extract { "consul_exporter.${consul_exporter_version}.tar.gz":
  strip   => 1,
  target  => '/usr/local/bin',
  creates => '/usr/local/bin/consul_exporter',
}->
file { '/usr/local/bin/consul_exporter':
  ensure => file,
  owner  => root,
  group  => root,
  mode   => '0755',
}

systemd::unit_file { 'consul_exporter.service':
  source => 'puppet:///nubis/files/consul_exporter.systemd',
}

file { '/etc/confd/conf.d/consul_exporter.toml':
  ensure => file,
  owner  => root,
  group  => root,
  mode   => '0644',
  source => 'puppet:///nubis/files/confd/conf.d/consul_exporter.toml',
}

file { '/etc/confd/templates/consul_exporter.tmpl':
  ensure => file,
  owner  => root,
  group  => root,
  mode   => '0644',
  source => 'puppet:///nubis/files/confd/templates/consul_exporter.tmpl',
}
