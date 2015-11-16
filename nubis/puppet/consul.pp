class { 'consul':
  version => '0.5.2',
  purge_config_dir => false,
  manage_service => false,
  
  config_hash => {
      'data_dir'        => '/var/lib/consul',
      'log_level'       => 'INFO',
      'ui_dir'          => '/var/lib/consul/ui',
      'client_addr'     => '0.0.0.0',
      'leave_on_terminate' => true,
      'server'          => true,
      'enable_syslog'   => true,
      'dns_config'      => {
          'enable_truncate' => true,
      },
  }
}

package { 'libwww-perl':
  ensure => present,
}

package { 'libjson-perl':
  ensure => present,
}

package { 'liblwp-useragent-determined-perl':
  ensure => present,
}

file { '/usr/local/bin/consul-get-or-set':
    ensure => file,
    owner  => root,
    group  => root,
    mode   => '0755',
    source => 'puppet:///nubis/files/consul-get-or-set',
    require => [
      Package['libwww-perl'],
      Package['libjson-perl'],
      Package['liblwp-useragent-determined-perl'],
    ],
}

file { '/etc/nubis.d/consul-publish-registration':
    ensure => file,
    owner  => root,
    group  => root,
    mode   => '0755',
    source => 'puppet:///nubis/files/consul-publish-registration',
}

file { '/usr/local/bin/consul-asg-join':
    ensure => file,
    owner  => root,
    group  => root,
    mode   => '0755',
    source => 'puppet:///nubis/files/consul-asg-join',
}

cron::job {
  'consul-asg-join':
    minute      => '*/5',
    hour        => '*',
    date        => '*',
    month       => '*',
    weekday     => '*',
    user        => 'root',
    command     => '/usr/local/bin/consul-asg-join >/dev/null',
    environment => [ 'PATH="/usr/local/bin:/usr/bin:/bin"', 'SHELL=/bin/bash' ],
}

# Install consul backup script and create cron for it
file { '/usr/local/sbin/consul-backup':
    ensure => file,
    owner  => root,
    group  => root,
    mode   => '0755',
    source => 'puppet:///nubis/files/consul-backup',
}

cron::hourly { 'consul_backup':
    minute      => '0',
    user        => 'root',
    command     => '/usr/local/sbin/consul-backup',
    environment => [ 'PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"', 'SHELL=/bin/bash' ],
    require     => File['/usr/local/sbin/consul-backup']
}
