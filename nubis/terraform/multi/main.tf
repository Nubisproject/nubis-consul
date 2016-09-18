#ws_launch_configuration Configure the AWS Provider
provider "aws" {
  region  = "${var.aws_region}"
}

resource "atlas_artifact" "nubis-consul" {
  count = "${var.enabled}"

  name = "nubisproject/nubis-consul"
  type = "amazon.image"

  lifecycle {
    create_before_destroy = true
  }

  metadata {
    project_version = "${var.nubis_version}"
  }
}

resource "aws_launch_configuration" "consul" {
  count = "${var.enabled * length(split(",", var.environments))}"

  depends_on = [
    "null_resource.credstash",
    "null_resource.credstash-public",
  ]

  lifecycle {
    create_before_destroy = true
  }

  name_prefix = "${var.project}-${element(split(",",var.environments), count.index)}-${var.aws_region}-"

  # Somewhat nasty, since Atlas doesn't have an elegant way to access the id for a region
  # the id is "region:ami,region:ami,region:ami"
  # so we split it all and find the index of the region
  # add on, and pick that element
  image_id = "${ element(split(",",replace(atlas_artifact.nubis-consul.id,":",",")) ,1 + index(split(",",replace(atlas_artifact.nubis-consul.id,":",",")), var.aws_region)) }"

  instance_type        = "t2.nano"
  key_name             = "${var.key_name}"
  iam_instance_profile = "${element(aws_iam_instance_profile.consul.*.name, count.index)}"

  security_groups = [
    "${element(aws_security_group.consul.*.id, count.index)}",
    "${element(split(",",var.internet_access_security_groups), count.index)}",
    "${element(split(",",var.shared_services_security_groups), count.index)}",
  ]

  user_data = <<EOF
NUBIS_PROJECT=${var.project}
NUBIS_ENVIRONMENT=${element(split(",",var.environments), count.index)}
NUBIS_ACCOUNT=${var.service_name}
NUBIS_DOMAIN=${var.domain}
CONSUL_ACL_DEFAULT_POLICY=${var.acl_default_policy}
CONSUL_ACL_DOWN_POLICY=${var.acl_down_policy}
NUBIS_BUMP=${md5("${var.datadog_api_key}${element(template_file.mig.*.rendered,count.index)}")}
EOF
}

resource "aws_autoscaling_group" "consul" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  #XXX: Fugly, assumes 3 subnets per environments, bad assumption, but valid ATM
  vpc_zone_identifier = [
    "${element(split(",",var.private_subnets), (count.index * 3) + 0 )}",
    "${element(split(",",var.private_subnets), (count.index * 3) + 1 )}",
    "${element(split(",",var.private_subnets), (count.index * 3) + 2 )}",
  ]

  name = "${var.project}-${element(split(",",var.environments), count.index)} (LC ${element(aws_launch_configuration.consul.*.name, count.index)})"

  max_size                  = "${var.servers}"
  min_size                  = "${var.servers}"
  health_check_grace_period = 10
  health_check_type         = "ELB"
  desired_capacity          = "${var.servers}"
  force_delete              = true
  launch_configuration      = "${element(aws_launch_configuration.consul.*.name, count.index)}"

  # This resource isn't considered created by TF until we have var.servers in rotation
  #  wait_for_elb_capacity = "${var.servers - 1}"
  wait_for_elb_capacity = "${var.servers}"

  wait_for_capacity_timeout = "60m"

  load_balancers = [
    "${element(aws_elb.consul.*.name, count.index)}",
    "${element(aws_elb.consul-public.*.name, count.index)}",
  ]

  tag {
    key                 = "Name"
    value               = "Consul server node (${var.nubis_version}) for ${var.service_name} in ${element(split(",",var.environments), count.index)}"
    propagate_at_launch = true
  }

  tag {
    key                 = "ServiceName"
    value               = "${var.project}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "${element(split(",",var.environments), count.index)}"
    propagate_at_launch = true
  }
}

resource "aws_security_group" "consul" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name        = "${var.project}-${element(split(",",var.environments), count.index)}"
  description = "Consul internal traffic + maintenance."

  vpc_id = "${element(split(",",var.vpc_ids), count.index)}"

  # XXX: These are for maintenance
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # XXX: Redundant
  # Consul TCP
  ingress {
    self      = true
    from_port = 8300
    to_port   = 8302
    protocol  = "tcp"
  }

  # Consul UDP
  ingress {
    self      = true
    from_port = 8300
    to_port   = 8302
    protocol  = "udp"
  }

  ingress {
    from_port = 8500
    to_port   = 8500
    protocol  = "tcp"

    security_groups = [
      "${element(aws_security_group.elb.*.id, count.index)}",
      "${element(aws_security_group.elb-public.*.id, count.index)}",
    ]
  }

  # Put back Amazon Default egress all rule
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-${element(split(",",var.environments), count.index)}"
    Region      = "${var.aws_region}"
    Environment = "${element(split(",",var.environments), count.index)}"
  }
}

## Create a new load balancer
resource "aws_elb" "consul" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name = "elb-${var.project}-${element(split(",",var.environments), count.index)}"

  #XXX: Fugly, assumes 3 subnets per environments, bad assumption, but valid ATM
  subnets = [
    "${element(split(",",var.private_subnets), (count.index * 3) + 0 )}",
    "${element(split(",",var.private_subnets), (count.index * 3) + 1 )}",
    "${element(split(",",var.private_subnets), (count.index * 3) + 2 )}",
  ]

  # This is an internal ELB, only accessible form inside the VPC
  internal = true

  listener {
    instance_port     = 8500
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  listener {
    instance_port      = 8500
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = "${element(aws_iam_server_certificate.consul_web_ui.*.arn, count.index)}"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:8500/v1/status/peers"
    interval            = 60
  }

  cross_zone_load_balancing = true

  security_groups = [
    "${element(aws_security_group.elb.*.id, count.index)}",
  ]

  tags = {
    Name        = "elb-${var.project}-${element(split(",",var.environments), count.index)}"
    Region      = "${var.aws_region}"
    Environment = "${element(split(",",var.environments), count.index)}"
  }
}

# Create the public load-balancer
#
resource "aws_elb" "consul-public" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name = "elb-${var.project}-${element(split(",",var.environments), count.index)}-public"

  #XXX: Fugly, assumes 3 subnets per environments, bad assumption, but valid ATM
  subnets = [
    "${element(split(",",var.public_subnets), (count.index * 3) + 0 )}",
    "${element(split(",",var.public_subnets), (count.index * 3) + 1 )}",
    "${element(split(",",var.public_subnets), (count.index * 3) + 2 )}",
  ]

  # This is an internet facing ELB
  internal = false

  listener {
    instance_port      = 8500
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = "${element(aws_iam_server_certificate.consul_web_public.*.arn, count.index)}"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:8500/v1/status/peers"
    interval            = 60
  }

  cross_zone_load_balancing = true

  security_groups = [
    "${element(aws_security_group.elb-public.*.id, count.index)}",
  ]

  tags = {
    Name        = "elb-${var.project}-${element(split(",",var.environments), count.index)}-public"
    Region      = "${var.aws_region}"
    Environment = "${element(split(",",var.environments), count.index)}"
  }
}

resource "aws_security_group" "elb" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name        = "elb-${var.project}-${element(split(",",var.environments), count.index)}"
  description = "Allow inbound traffic for consul"

  vpc_id = "${element(split(",",var.vpc_ids), count.index)}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Put back Amazon Default egress all rule
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "elb-${var.project}-${element(split(",",var.environments), count.index)}"
    Region      = "${var.aws_region}"
    Environment = "${element(split(",",var.environments), count.index)}"
  }
}

resource "aws_security_group" "elb-public" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name        = "elb-${var.project}-${element(split(",",var.environments), count.index)}-public"
  description = "Allow inbound traffic for consul"

  vpc_id = "${element(split(",",var.vpc_ids), count.index)}"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["${split(",", var.allowed_public_cidrs)}"]
  }

  # Put back Amazon Default egress all rule
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_route53_zone" "consul" {
  count  = "${var.enabled * length(split(",", var.environments))}"
  name   = "${var.project}.${element(split(",",var.environments), count.index)}.${var.aws_region}.${var.service_name}.${var.domain}"
  vpc_id = "${element(split(",",var.vpc_ids), count.index)}"
}

resource "aws_route53_record" "ui" {
  count   = "${var.enabled * length(split(",", var.environments))}"
  zone_id = "${element(aws_route53_zone.consul.*.zone_id, count.index)}"
  name    = "ui"
  type    = "CNAME"
  ttl     = "30"
  records = ["${element(aws_elb.consul.*.dns_name, count.index)}"]
}

resource "aws_route53_record" "public" {
  count   = "${var.enabled * length(split(",", var.environments))}"
  zone_id = "${var.zone_id}"
  name    = "public.${var.project}.${element(split(",",var.environments), count.index)}"
  type    = "CNAME"
  ttl     = "30"
  records = ["dualstack.${element(aws_elb.consul-public.*.dns_name, count.index)}"]
}

#XXX: Need UUID bucket
resource "aws_s3_bucket" "consul_backups" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  bucket = "nubis-${var.project}-backup-${element(split(",",var.environments), count.index)}-${var.aws_region}-${var.service_name}"
  acl    = "private"

  # Nuke the bucket content on deletion
  force_destroy = true

  versioning {
    enabled = true
  }

  tags = {
    Name        = "nubis-${var.project}-backup-${element(split(",",var.environments), count.index)}-${var.aws_region}-${var.service_name}"
    Region      = "${var.aws_region}"
    Environment = "${element(split(",",var.environments), count.index)}"
  }
}

resource "aws_iam_instance_profile" "consul" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name  = "${var.project}-${element(split(",",var.environments), count.index)}-${var.aws_region}"
  roles = ["${element(aws_iam_role.consul.*.name, count.index)}"]
}

resource "aws_iam_role" "consul" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name = "${var.project}-${element(split(",",var.environments), count.index)}-${var.aws_region}"
  path = "/nubis/consul/"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy" "consul" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name = "${var.project}-${element(split(",",var.environments), count.index)}-${var.aws_region}"
  role = "${element(aws_iam_role.consul.*.id, count.index)}"

  policy = <<EOF
{
    "Version": "2008-10-17",
    "Statement": [
        {
            "Action": [
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeAutoScalingGroups",
                "ec2:DescribeInstances",
                "elasticloadbalancing:DescribeLoadBalancers"
            ],
            "Resource": "*",
            "Effect": "Allow"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy" "consul_backups" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name = "${var.project}-${element(split(",",var.environments), count.index)}-${var.aws_region}-backups"
  role = "${element(aws_iam_role.consul.*.id, count.index)}"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": [ "${element(aws_s3_bucket.consul_backups.*.arn,count.index)}" ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": [ "${element(aws_s3_bucket.consul_backups.*.arn,count.index)}/*" ]
        }
    ]
}
EOF
}

resource "aws_iam_role_policy" "credstash" {
  count = "${var.enabled * length(split(",", var.environments))}"

  #XXX
  lifecycle {
    create_before_destroy = true
  }

  name = "${var.project}-${element(split(",",var.environments), count.index)}-${var.aws_region}-credstash"
  role = "${element(aws_iam_role.consul.*.id, count.index)}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:GenerateDataKey*",
        "kms:Encrypt"
      ],
      "Resource": [
        "${var.credstash_key}"
      ],
      "Condition": {
        "ForAllValues:StringEquals": {
          "kms:EncryptionContext:environment": "${element(split(",",var.environments), count.index)}",
          "kms:EncryptionContext:service": "nubis",
          "kms:EncryptionContext:region": "${var.aws_region}"
        }
      }
    },
    {
      "Resource": "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/credential-store",
      "Action": [
        "dynamodb:PutItem"
      ],
      "Effect": "Allow",
      "Condition": {
        "ForAllValues:StringLike": {
          "dynamodb:LeadingKeys": [
            "nubis/${element(split(",",var.environments), count.index)}/*"
          ]
        }
      }
    }
  ]
}
EOF
}

resource "tls_private_key" "consul_web" {
  count = "${var.enabled}"

  lifecycle {
    create_before_destroy = true
  }

  algorithm = "RSA"
}

resource "tls_self_signed_cert" "consul_web_public" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  key_algorithm   = "${tls_private_key.consul_web.algorithm}"
  private_key_pem = "${tls_private_key.consul_web.private_key_pem}"

  # Certificate expires after one year
  validity_period_hours = 8760

  # Generate a new certificate if Terraform is run within three
  # hours of the certificate's expiration time. ( 7 days )
  early_renewal_hours = 168

  # Reasonable set of uses for a server SSL certificate.
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  subject {
    common_name  = "public.${var.project}.${element(split(",",var.environments), count.index)}.${var.aws_region}.${var.service_name}.${var.domain}"
    organization = "Nubis Platform"
  }
}

resource "tls_self_signed_cert" "consul_web_ui" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  key_algorithm   = "${tls_private_key.consul_web.algorithm}"
  private_key_pem = "${tls_private_key.consul_web.private_key_pem}"

  # Certificate expires after one year
  validity_period_hours = 8760

  # Generate a new certificate if Terraform is run within three
  # hours of the certificate's expiration time. ( 7 days )
  early_renewal_hours = 168

  is_ca_certificate = true

  # Reasonable set of uses for a server SSL certificate.
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "cert_signing",
  ]

  subject {
    common_name  = "ui.${var.project}.${element(split(",",var.environments), count.index)}.${var.aws_region}.${var.service_name}.${var.domain}"
    organization = "Nubis Platform"
  }
}

resource "aws_iam_server_certificate" "consul_web_public" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  name_prefix      = "${var.project}-${element(split(",",var.environments), count.index)}-${var.aws_region}-public-"
  certificate_body = "${element(tls_self_signed_cert.consul_web_public.*.cert_pem, count.index)}"
  private_key      = "${tls_private_key.consul_web.private_key_pem}"

  # Amazon lies about key creation and availability
  provisioner "local-exec" {
    command = "sleep 10"
  }
}

resource "aws_iam_server_certificate" "consul_web_ui" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  name_prefix      = "${var.project}-${element(split(",",var.environments), count.index)}-${var.aws_region}-ui-"
  certificate_body = "${element(tls_self_signed_cert.consul_web_ui.*.cert_pem, count.index)}"
  private_key      = "${tls_private_key.consul_web.private_key_pem}"

  # Amazon lies about key creation and availability

  #provisioner "local-exec" {

  #  command = "sleep 10"

  #}
}

resource "tls_private_key" "gossip" {
  count = "${var.enabled}"

  lifecycle {
    create_before_destroy = true
  }

  algorithm = "RSA"
}

resource "tls_self_signed_cert" "gossip" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  key_algorithm   = "${tls_private_key.gossip.algorithm}"
  private_key_pem = "${tls_private_key.gossip.private_key_pem}"

  # Certificate expires after one year
  validity_period_hours = 8760

  # Generate a new certificate if Terraform is run within three
  # hours of the certificate's expiration time. ( 7 days )
  early_renewal_hours = 168

  is_ca_certificate = true

  # Reasonable set of uses for a server SSL certificate.
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "cert_signing",
    "server_auth",
    "client_auth",
  ]

  subject {
    common_name  = "gossip.${var.project}.${element(split(",",var.environments), count.index)}.${var.aws_region}.${var.service_name}.${var.domain}"
    organization = "Nubis Platform"
  }
}

# This null resource is responsible for publishing platform secrets to Credstash
resource "null_resource" "credstash-public" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  # Important to list here every variable that affects what needs to be put into credstash
  triggers {
    secret    = "${var.credstash_key}"
    cacert    = "${element(tls_self_signed_cert.consul_web_ui.*.cert_pem, count.index)}"
    region    = "${var.aws_region}"
    version   = "${var.nubis_version}"
    context   = "region=${var.aws_region} environment=${element(split(",",var.environments), count.index)} service=nubis"
    credstash = "credstash -r ${var.aws_region} put -k ${var.credstash_key} -a nubis/${element(split(",",var.environments), count.index)}"
  }

  # Consul UI SSL Certificate
  provisioner "local-exec" {
    command = "${self.triggers.credstash}/ssl/cacert '${element(tls_self_signed_cert.consul_web_ui.*.cert_pem, count.index)}' ${self.triggers.context}"
  }
}

# This null resource is responsible for publishing secrets to Credstash
resource "null_resource" "credstash" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  # Important to list here every variable that affects what needs to be put into credstash
  triggers {
    secret           = "${var.credstash_key}"
    master_acl_token = "${var.master_acl_token}"
    datadog_api_key  = "${var.datadog_api_key}"
    version          = "${var.nubis_version}"
    mig              = "${md5(element(template_file.mig.*.rendered,count.index))}"
    ssl_key          = "${element(tls_private_key.gossip.*.private_key_pem, count.index)}"
    ssl_cert         = "${element(tls_self_signed_cert.gossip.*.cert_pem, count.index)}"
    region           = "${var.aws_region}"
    context          = "region=${var.aws_region} environment=${element(split(",",var.environments), count.index)} service=${var.project}"
    credstash        = "credstash -r ${var.aws_region} put -k ${var.credstash_key} -a ${var.project}/${element(split(",",var.environments), count.index)}"
  }

  # Consul gossip secret
  provisioner "local-exec" {
    command = "${self.triggers.credstash}/secret ${var.consul_secret} ${self.triggers.context}"
  }

  # Consul Master ACL Token
  provisioner "local-exec" {
    command = "${self.triggers.credstash}/master_acl_token ${var.master_acl_token} ${self.triggers.context}"
  }

  # Consul SSL key
  provisioner "local-exec" {
    command = "${self.triggers.credstash}/ssl/key '${element(tls_private_key.gossip.*.private_key_pem, count.index)}' ${self.triggers.context}"
  }

  # Consul SSL Certificate
  provisioner "local-exec" {
    command = "${self.triggers.credstash}/ssl/cert '${element(tls_self_signed_cert.gossip.*.cert_pem, count.index)}' ${self.triggers.context}"
  }

  # Datadog
  provisioner "local-exec" {
    command = "${self.triggers.credstash}/datadog/api_key '${var.datadog_api_key}' ${self.triggers.context}"
  }
}

resource "template_file" "mig" {
  count = "${var.enabled * length(split(",", var.environments))}"

  lifecycle {
    create_before_destroy = true
  }

  template = <<TEMPLATE
MIG_AGENT_CRT=""
MIG_AGENT_KEY=""
MIG_CA_CRT=""
MIG_RELAY_PASSWORD=""
MIG_RELAY_USER="agent-it-nubis"
TEMPLATE

  vars = {
  }
}
