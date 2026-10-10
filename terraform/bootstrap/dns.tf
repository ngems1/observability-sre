# Public certificate for the custom domain, issued once and kept outside the nightly teardown.
#
# Why here and not in infra/platform: ACM certificates are free, and DNS validation takes a few minutes.
# Destroying and re-issuing the certificate on every rebuild would add that wait to every single apply,
# so it lives in bootstrap, which survives `Destroy`. The platform root looks it up by domain name.
#
# The hosted zone itself is NOT managed by Terraform: it is read with a data source. Recreating a zone
# changes its NS records and breaks the registered domain's delegation, so it stays clickops on purpose.

data "aws_route53_zone" "this" {
  count        = var.domain_name == "" ? 0 : 1
  name         = "${var.domain_name}."
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  count                     = var.domain_name == "" ? 0 : 1
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"] # dev.<domain>, opsdesk.<domain>, anything later
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = var.domain_name == "" ? {} : {
    for o in aws_acm_certificate.this[0].domain_validation_options : o.domain_name => o
  }

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true # the apex and the wildcard validate through the same record name
}

resource "aws_acm_certificate_validation" "this" {
  count                   = var.domain_name == "" ? 0 : 1
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
