resource "aws_route53_zone" "public" {
  count = var.route53_zone_enabled ? 1 : 0

  name = var.domain_name

  tags = merge(local.common_tags, {
    Name = "${var.domain_name}-public-zone"
  })
}

resource "aws_route53_record" "cloudfront_alias_a" {
  count = var.route53_zone_enabled && var.edge_enabled ? 1 : 0

  zone_id = aws_route53_zone.public[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.application[0].domain_name
    zone_id                = aws_cloudfront_distribution.application[0].hosted_zone_id
    evaluate_target_health = false
  }
}
