class { 'consul':
  version => '0.5.2',
  purge_config_dir => false,
  manage_service => false,
  
  config_hash => {
      'data_dir'        => '/var/lib/consul',
      'log_level'       => 'INFO',
      'ui_dir'          => '/var/lib/consul/ui',
      'client_addr'     => '0.0.0.0',
      'server'          => true,
      'enable_syslog'   => true,
      'dns_config'      => {
          'enable_truncate' => true,
      },
  }
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
    command     => '/usr/local/sbin/consul-backup > /dev/null > 2>&1',
    environment => [ 'PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"', 'SHELL=/bin/bash' ],
    require     => File['/usr/local/sbin/consul-backup']
}
