/*
SFTP modulo
Creación de una Elastic IP por zona de disponibilidad (1 para poc)
Creación de un VPC endpoint asociado al servicio AWS Transfer
Creación de un IAM Role asociado a política de S3
Creación de un SG asociado a las IPs permitidas
Creación de una clave SSH para usuario sftp
Creación de un servidor AWS Transfer Family con endpoint VPC y SG
Creación de un usuario en AWS Transfer con una clave SSH propia

-------------
aws_eip -> submodulo
aws_vpc_endpoint
aws_iam_role
aws_security_group
aws_transfer_server
local-exec 
aws_transfer_ssh_key
*/

module "eip" {
  source    = "./eip/"
  for_each  = toset(var.subnet_ids)
  subnet_id = each.value
}

# resource "aws_vpc_endpoint" "sftp" {
#   vpc_id            = var.vpc_id
#   service_name      = "com.amazonaws.eu-west-1.transfer.server"
#   vpc_endpoint_type = "Interface"
#   subnet_ids        = var.subnet_ids

#   security_group_ids = [
#     aws_security_group.sftp_allow.id,
#   ]

#   private_dns_enabled = true
# }

resource "aws_security_group" "sftp_allow" {
  name        = "sftp_allow"
  description = "Allow SFTP inbound traffic"
  vpc_id      = var.vpc_id

  ingress {
    description = "sftp from all"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowlist]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "sftp_allow"
  }
}

resource "aws_cloudwatch_log_group" "sftp-logging" {
  name              = "sftp-logging"
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

    resources = ["$(aws_cloudwatch_log_group.sftp-logging.arn)"]
  }
}

resource "aws_iam_policy" "sftp-logging" {
  name        = "sftp-logging"
  policy      = data.aws_iam_policy_document.sftp-logging.json
  depends_on  = [data.aws_iam_policy_document.sftp-logging]
}

resource "aws_iam_role" "sftp-logging" {
  name                = "sftp-logging"
  assume_role_policy  = data.aws_iam_policy_document.sftp-logging.json
  tags = {
    tag-key = "SFTP"
  }
}

resource "aws_iam_role_policy_attachment" "sftp-logging-attach" {
  role       = aws_iam_role.sftp-logging.name
  policy_arn = aws_iam_policy.sftp-logging.arn
}


data "aws_iam_policy_document" "sftp-s3" {
  statement {
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = [
      var.input_bucket,
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObjectVersion",
      "s3:GetObject",
      "s3:DeleteObjectVersion",
      "s3:DeleteObject"
    ]

    resources = [
      "${var.input_bucket}/input/*",
    ]
  }
}

resource "aws_iam_policy" "sftp-s3" {
  name       = "sftp-s3"
  policy     = data.aws_iam_policy_document.sftp-s3.json
  depends_on = [data.aws_iam_policy_document.sftp-s3]
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
  policy_arn = aws_iam_policy.sftp-s3.arn
}

# locals {
#   allocation_ids = [for p in var.subnet_ids : module.eip[p].eip_id]
# }

resource "aws_transfer_server" "this" {
  identity_provider_type = "SERVICE_MANAGED"
  endpoint_type          = "VPC"
  logging_role           = join("", aws_iam_role.sftp-logging[*].arn)
  endpoint_details {
    vpc_id = var.vpc_id
    #vpc_endpoint_id = aws_vpc_endpoint.sftp.id # DEPRECATED BY AWS
    # ESTOFUNCIONA address_allocation_ids = [module.eip["subnet-011b3f35e110f8330"].eip_id]
    # NOFUNKA address_allocation_ids = [{ for p in keys(var.subnet_ids) : p => module.eip[p].eip_id }]
    # FUNKA address_allocation_ids = [module.eip[var.subnet_ids[0]].eip_id]
    # nofunka address_allocation_ids = [tolist(local.allocation_ids)]
    security_group_ids     = [aws_security_group.sftp_allow.id]
    address_allocation_ids = [module.eip[var.subnet_ids[0]].eip_id, module.eip[var.subnet_ids[1]].eip_id, module.eip[var.subnet_ids[2]].eip_id]
    subnet_ids             = var.subnet_ids
  }
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

