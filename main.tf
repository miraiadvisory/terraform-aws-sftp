module "eip" {
  source    = "./eip/"
  for_each  = toset(var.subnet_ids)
  subnet_id = each.value
}

resource "aws_security_group" "sftp_allow" {
  name        = "sftp_allow"
  description = "Allow SFTP inbound traffic"
  vpc_id      = var.vpc_id

  ingress {
    description = "sftp from all"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowlist
  }

  egress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = var.allowlist
  }

  tags = {
    Name = "sftp_allow"
  }
}

resource "aws_cloudwatch_log_group" "sftp-logging" {
  name              = "/aws/transfer/${aws_transfer_server.this.id}"
  retention_in_days = 30
}

data "aws_iam_policy_document" "sftp-logging" {
  statement {
    sid       = "CloudWatchAccessForAWSTransfer"
    effect    = "Allow"

    actions   = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:CreateLogGroup",
      "logs:PutLogEvents"
    ]

    resources = ["${aws_cloudwatch_log_group.sftp-logging.arn}:*"]
  }
}

resource "aws_iam_policy" "sftp-logging" {
  name        = "sftp-logging"
  policy      = data.aws_iam_policy_document.sftp-logging.json
  depends_on  = [data.aws_iam_policy_document.sftp-logging]
}

resource "aws_iam_role" "sftp-logging" {
  name                = "sftp-logging"
  assume_role_policy  = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "transfer.amazonaws.com"
        }
      },
    ]
  })
  tags = {
    tag-key = "SFTP"
  }
}

resource "aws_iam_role_policy_attachment" "sftp-logging-attach" {
  role       = aws_iam_role.sftp-logging.name
  policy_arn = aws_iam_policy.sftp-logging.arn
}

resource "aws_iam_role" "sftp-s3" {
  name = "sftp-s3"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "transfer.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    tag-key = "SFTP"
  }
}

resource "aws_iam_role_policy_attachment" "sftp-attach" {
  role       = aws_iam_role.sftp-s3.name
  policy_arn = var.sftp_policy
}

resource "aws_transfer_server" "this" {
  identity_provider_type = "SERVICE_MANAGED"
  endpoint_type          = "VPC"
  logging_role           = join("", aws_iam_role.sftp-logging[*].arn)
  endpoint_details {
    vpc_id = var.vpc_id
    security_group_ids     = [aws_security_group.sftp_allow.id]
    address_allocation_ids = [module.eip[var.subnet_ids[0]].eip_id, module.eip[var.subnet_ids[1]].eip_id, module.eip[var.subnet_ids[2]].eip_id]
    subnet_ids             = var.subnet_ids
  }
  pre_authentication_login_banner = var.pre_authentication_login_banner
}

resource "random_string" "sftp" {
  length  = 16
  special = false
  keepers = {
    zone_name = var.zone_name
  }
}

resource "aws_route53_record" "sftp" {
  zone_id = var.zone_id
  name    = trimsuffix("_${random_string.sftp.id}.${var.zone_name}", ".")
  type    = "CNAME"
  ttl     = "60"
  records = [aws_transfer_server.this.endpoint]
}

resource "aws_route53_record" "sftp_uploads" {
  zone_id = var.zone_id
  name    = "uploads.${var.zone_name}"
  type    = "CNAME"
  ttl     = "60"
  records = [aws_transfer_server.this.endpoint]
}

