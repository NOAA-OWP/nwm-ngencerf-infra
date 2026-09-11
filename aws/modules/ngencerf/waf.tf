# WAFv2 web ACL fronting the ALB. Regional scope (NOT CloudFront, ALB is regional).
# Default action = allow; rules opt requests into count/block via var.waf_rule_action.
# Managed rule groups: OWASP common, known-bad inputs, Amazon IP reputation, SQLi.
# Rate-based per source IP: /api/auth/* 100/5min (anti-brute-force), /api/* 2000/5min.
# Skipped intentionally: BotControl (flags the CLI as a bot) and AnonymousIpList
# (false-positives on researchers behind VPNs/cloud IPs).
# SC-7: perimeter boundary protection. SI-3/SI-4: malicious code + monitoring.
# SC-5: rate-based rules provide DoS protection.

resource "aws_wafv2_web_acl" "main" {
  name        = "${var.name_prefix}-waf"
  scope       = "REGIONAL"
  description = "ngencerf perimeter WAF - managed rule groups + per-IP rate limits."

  default_action {
    allow {}
  }

  # --- Managed rule groups -------------------------------------------------

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      dynamic "count" {
        for_each = var.waf_rule_action == "count" ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = var.waf_rule_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      dynamic "count" {
        for_each = var.waf_rule_action == "count" ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = var.waf_rule_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 3

    override_action {
      dynamic "count" {
        for_each = var.waf_rule_action == "count" ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = var.waf_rule_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-IpReputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 4

    override_action {
      dynamic "count" {
        for_each = var.waf_rule_action == "count" ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = var.waf_rule_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-SQLi"
      sampled_requests_enabled   = true
    }
  }

  # --- Rate-based rules ----------------------------------------------------
  # Anti-brute-force on /api/auth/* (Django mounts djoser at api/auth/);
  # bulk-CLI-friendly ceiling on /api/*. The auth rule fires first (lower
  # priority number) so /api/auth/jwt/create gets the tighter 100/5min cap
  # before the broader /api/* rule sees it.

  rule {
    name     = "rate-auth"
    priority = 10

    action {
      dynamic "count" {
        for_each = var.waf_rule_action == "count" ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.waf_rule_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            positional_constraint = "STARTS_WITH"
            search_string         = "/api/auth/"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-RateAuth"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-api"
    priority = 11

    action {
      dynamic "count" {
        for_each = var.waf_rule_action == "count" ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.waf_rule_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            positional_constraint = "STARTS_WITH"
            search_string         = "/api/"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-RateApi"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }
}

# Two-resource pattern (ACL + association): one ACL can attach to many
# targets (ALB / API Gateway / AppSync), and targets can be swapped
# without recreating the ACL.
resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = module.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# Send all WAF request decisions to a dedicated CloudWatch log group. AWS
# requires the log group name to start with "aws-waf-logs-", a naming
# convention enforced by the WAF service when wiring logging.
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
}
