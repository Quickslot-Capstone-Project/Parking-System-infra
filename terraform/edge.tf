locals {
  cloudfront_aliases                 = length(var.cloudfront_aliases) > 0 ? var.cloudfront_aliases : [var.domain_name]
  cloudfront_certificate_domain_name = coalesce(var.cloudfront_certificate_domain_name, var.domain_name)
  prod_alb_origin_domain_name        = var.edge_enabled ? coalesce(var.prod_alb_dns_name, try(data.aws_lb.prod_alb[0].dns_name, null)) : null
}

data "aws_lb" "prod_alb" {
  count = var.edge_enabled && var.prod_alb_dns_name == null ? 1 : 0

  name = var.prod_alb_name
}

data "aws_acm_certificate" "cloudfront" {
  count = var.edge_enabled ? 1 : 0

  domain      = local.cloudfront_certificate_domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = var.edge_enabled ? 1 : 0

  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host_header" {
  count = var.edge_enabled ? 1 : 0

  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_wafv2_web_acl" "cloudfront" {
  count = var.edge_enabled ? 1 : 0

  name        = "${local.name_prefix}-cloudfront-waf"
  description = "Managed WAF rules for the ${var.domain_name} CloudFront distribution."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cloudfront-waf"
  })
}

resource "aws_cloudfront_distribution" "application" {
  count = var.edge_enabled ? 1 : 0

  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.name_prefix} production application"
  aliases         = local.cloudfront_aliases
  web_acl_id      = aws_wafv2_web_acl.cloudfront[0].arn

  origin {
    domain_name = local.prod_alb_origin_domain_name
    origin_id   = "prod-alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = var.cloudfront_origin_protocol_policy
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "prod-alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]
    compress               = true

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.cloudfront[0].arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method       = "sni-only"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cloudfront"
  })
}
