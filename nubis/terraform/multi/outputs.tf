#output "internal-address" {
#  value = "http://${aws_route53_record.ui.fqdn}/"
#}
#output "public-address" {
#  value = "https://${aws_route53_record.public.fqdn}/"
#}
#output "elb-address" {
#  value = "dualstack.${aws_elb.consul-public.dns_name}"
#}

output "iam_roles" {
  value = "${join(",",aws_iam_role.consul.*.id)}"
}
