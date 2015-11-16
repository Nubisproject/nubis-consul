# Configure the AWS Provider
provider "aws" {
    access_key = "${var.aws_access_key}"
    secret_key = "${var.aws_secret_key}"
    region = "${var.region}"
}

resource "aws_launch_configuration" "consul" {
    lifecycle { create_before_destroy = true }
    image_id = "${var.ami}"
    instance_type = "t2.micro"
    key_name = "${var.key_name}"
    iam_instance_profile = "${aws_iam_instance_profile.consul.name}"

    security_groups = [
      "${aws_security_group.consul.id}",
      "${var.internet_security_group_id}",
      "${var.shared_services_security_group_id}",
    ]

    user_data = <<EOF
NUBIS_PROJECT=${var.project}
NUBIS_ENVIRONMENT=${var.environment}
NUBIS_ACCOUNT=${var.service_name}
NUBIS_DOMAIN=${var.domain}
CONSUL_SERVER=1
CONSUL_MASTER_ACL_TOKEN=${var.master_acl_token}
CONSUL_ACL_DEFAULT_POLICY=${var.acl_default_policy}
CONSUL_ACL_DOWN_POLICY=${var.acl_down_policy}
CONSUL_SECRET=${var.consul_secret}
CONSUL_BOOTSTRAP_EXPECT=${var.servers}
CONSUL_KEY="${file("${var.ssl_key}")}"
CONSUL_CERT="${file("${var.ssl_cert}")}"
EOF
}

resource "aws_autoscaling_group" "consul" {
  lifecycle { create_before_destroy = true }
  vpc_zone_identifier = ["${split(",", var.private_subnets)}"]
  name = "${var.project}-${var.environment}"
  max_size = "${var.servers}"
  min_size = "${var.servers}"
  health_check_grace_period = 10
  health_check_type = "EC2"
  desired_capacity = "${var.servers}"
  force_delete = true
  launch_configuration = "${aws_launch_configuration.consul.name}"

  load_balancers = [
    "${aws_elb.consul.name}",
    "${aws_elb.consul-public.name}"
  ]

  tag {
    key = "Name"
    value = "Consul server node (v/${var.release}.${var.build}) for ${var.service_name} in ${var.environment}"
    propagate_at_launch = true
  }

  tag {
    key = "ServiceName"
    value = "${var.project}"
    propagate_at_launch = true
  }
}

resource "aws_security_group" "consul" {
  name = "${var.project}-${var.environment}"
  description = "Consul internal traffic + maintenance."
  

  vpc_id = "${var.vpc_id}"

  // These are for internal traffic (redundant, ssg does this)
  ingress {
    from_port = 8300
    to_port = 8303
    protocol = "tcp"
    security_groups = [
      "${var.shared_services_security_group_id}",
    ]
  }

  // This is for the gossip traffic (redundant, ssg does this)
  ingress {
    from_port = 8300
    to_port = 8303
    protocol = "udp"
    security_groups = [
      "${var.shared_services_security_group_id}",
    ]
  }

  // These are for maintenance
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 8500
    to_port = 8500
    protocol = "tcp"
    security_groups = [
      "${aws_security_group.elb.id}",
      "${aws_security_group.elb-public.id}"
    ]
  }

  # Put back Amazon Default egress all rule
  egress {
      from_port = 0
      to_port = 0
      protocol = "-1"
      cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create a new load balancer
resource "aws_elb" "consul" {
  name = "elb-${var.project}-${var.environment}"
  subnets = ["${split(",", var.public_subnets)}"]

  # This is an internal ELB, only accessible form inside the VPC
  internal = true

  listener {
    instance_port = 8500
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }

 listener {
    instance_port = 8500
    instance_protocol = "http"
    lb_port = 443
    lb_protocol = "https"
    ssl_certificate_id = "${var.https_cert_arn}"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    target = "HTTP:8500/v1/status/peers"
    interval = 60
  }

  cross_zone_load_balancing = true

  security_groups = [
    "${aws_security_group.elb.id}"
  ]
}

# Create the public load-balancer

resource "aws_elb" "consul-public" {
  name = "elb-${var.project}-${var.environment}-public"
  subnets = ["${split(",", var.public_subnets)}"]

  # This is an internet facing ELB
  internal = false

 listener {
    instance_port = 8500
    instance_protocol = "http"
    lb_port = 443
    lb_protocol = "https"
    ssl_certificate_id = "${var.https_cert_arn}"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    target = "HTTP:8500/v1/status/peers"
    interval = 5
  }

  cross_zone_load_balancing = true

  security_groups = [
    "${aws_security_group.elb-public.id}"
  ]
}

resource "aws_security_group" "elb" {
  name = "elb-${var.project}-${var.environment}"
  description = "Allow inbound traffic for consul"

  vpc_id = "${var.vpc_id}"

  ingress {
      from_port = 80
      to_port = 80
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
      from_port = 443
      to_port = 443
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }

  # Put back Amazon Default egress all rule
  egress {
      from_port = 0
      to_port = 0
      protocol = "-1"
      cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group" "elb-public" {
  name = "elb-${var.project}-${var.environment}-public"
  description = "Allow inbound traffic for consul"

  vpc_id = "${var.vpc_id}"

  ingress {
      from_port = 443
      to_port = 443
      protocol = "tcp"
      cidr_blocks = [ "${split(",", var.allowed_public_cidrs)}" ]
  }

  # Put back Amazon Default egress all rule
  egress {
      from_port = 0
      to_port = 0
      protocol = "-1"
      cidr_blocks = ["0.0.0.0/0"]
  }

}


resource "aws_route53_record" "ui" {
   zone_id = "${var.zone_id}"
   name = "ui.${var.project}.${var.environment}"
   type = "CNAME"
   ttl = "30"
   records = ["dualstack.${aws_elb.consul.dns_name}"]
}

resource "aws_route53_record" "public" {
   zone_id = "${var.zone_id}"
   name = "public.${var.project}.${var.environment}"
   type = "CNAME"
   ttl = "30"
   records = ["dualstack.${aws_elb.consul-public.dns_name}"]
}

resource "aws_s3_bucket" "consul_backups" {
    bucket = "nubis-${var.project}-backup-${var.environment}-${var.region}-${var.service_name}"
    acl = "private"

    # Nuke the bucket content on deletion
    force_destroy = true

    tags = {
        Name = "nubis-${var.project}-backupbucket-${var.environment}-${var.region}"
        Region = "${var.region}"
        Environment = "${var.environment}"
    }
}

resource "aws_iam_instance_profile" "consul" {
    name = "${var.project}-${var.environment}-${var.region}"
    roles = ["${aws_iam_role.consul.name}"]
}

resource "aws_iam_role" "consul" {
    name = "${var.project}-${var.environment}-${var.region}"
    path = "/"
    assume_role_policy = <<EOF
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
EOF
}

resource "aws_iam_role_policy" "consul" {
    name = "${var.project}-${var.environment}-${var.region}"
    role = "${aws_iam_role.consul.id}"
    policy = <<EOF
{
    "Version": "2008-10-17",
    "Statement": [
        {
            "Action": "autoscaling:DescribeAutoScalingInstances",
            "Resource": "*",
            "Effect": "Allow",
            "Sid": ""
        },
        {
            "Action": "autoscaling:DescribeAutoScalingGroups",
            "Resource": "*",
            "Effect": "Allow",
            "Sid": ""
        },
        {
            "Action": "ec2:DescribeInstances",
            "Resource": "*",
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

resource "aws_iam_role_policy" "consul_backups" {
    name    = "${var.project}-${var.environment}-${var.region}-backups"
    role    = "${aws_iam_role.consul.id}"
    policy  = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": [ "arn:aws:s3:::${aws_s3_bucket.consul_backups.id}" ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": [ "arn:aws:s3:::${aws_s3_bucket.consul_backups.id}/*" ]
        }
    ]
}
EOF
}
