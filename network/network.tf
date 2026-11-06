# FlashTicket : réseau à trois segments sur deux zones.
#   public     : point d'entrée (répartiteur HTTPS), reçoit Internet sur 443
#   applicatif : ticketpdf (8443) et SSH, n'accepte que le segment public
#   données    : base PostgreSQL (5432), n'accepte que le segment applicatif
# Les règles référencent des groupes de sécurité, pas des plages IP :
# seul un membre du groupe source peut joindre le groupe cible.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "azs" {
  type    = list(string)
  default = ["eu-west-3a", "eu-west-3b"]
}

provider "aws" {
  region = var.region
}

locals {
  # segment => [CIDR zone a, CIDR zone b]
  segments = {
    public = ["10.0.1.0/24", "10.0.11.0/24"]
    app    = ["10.0.2.0/24", "10.0.12.0/24"]
    data   = ["10.0.3.0/24", "10.0.13.0/24"]
  }
  subnets = merge([
    for seg, cidrs in local.segments : {
      for i, cidr in cidrs : "${seg}-${i}" => { segment = seg, cidr = cidr, az = var.azs[i] }
    }
  ]...)
  db_port  = 5432
  app_port = 8443
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "flashticket-vpc" }
}

resource "aws_subnet" "this" {
  for_each          = local.subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  # Aucune IP publique automatique, même dans le segment public : seul le répartiteur est exposé.
  map_public_ip_on_launch = false
  tags                    = { Name = "flashticket-${each.key}", Segment = each.value.segment }
}

# Seul le segment public a une route vers Internet ; applicatif et données n'en ont pas.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "flashticket-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "flashticket-public" }
}

resource "aws_route_table_association" "public" {
  for_each       = { for k, s in local.subnets : k => s if s.segment == "public" }
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public.id
}

# --- Groupes de sécurité (sans règle intégrée : toutes les règles sont explicites ci-dessous)

resource "aws_security_group" "public" {
  name        = "flashticket-public"
  description = "Segment public : HTTPS depuis Internet"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "app" {
  name        = "flashticket-app"
  description = "Segment applicatif : ticketpdf, depuis le segment public uniquement"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "data" {
  name        = "flashticket-data"
  description = "Segment donnees : PostgreSQL, depuis le segment applicatif uniquement"
  vpc_id      = aws_vpc.main.id
}

# Public : HTTPS entrant depuis Internet, sortie uniquement vers l'applicatif.
resource "aws_vpc_security_group_ingress_rule" "public_https" {
  security_group_id = aws_security_group.public.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "public_to_app" {
  security_group_id            = aws_security_group.public.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
}

# Applicatif : 8443 et SSH depuis le public uniquement (même logique que vm/nftables.conf).
resource "aws_vpc_security_group_ingress_rule" "app_from_public" {
  for_each                     = toset(["22", tostring(local.app_port)])
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.public.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}

resource "aws_vpc_security_group_egress_rule" "app_to_data" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.data.id
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
}

# Applicatif -> API AWS (file SQS, table DynamoDB) en HTTPS.
# shortcut: 0.0.0.0/0 sur 443 faute de NAT/VPC endpoints ; à restreindre aux préfixes des endpoints en production.
resource "aws_vpc_security_group_egress_rule" "app_https_aws_api" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Données : PostgreSQL depuis l'applicatif uniquement, aucune sortie.
resource "aws_vpc_security_group_ingress_rule" "data_from_app" {
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_ids" {
  value = { for k, s in aws_subnet.this : k => s.id }
}

output "security_group_ids" {
  value = {
    public = aws_security_group.public.id
    app    = aws_security_group.app.id
    data   = aws_security_group.data.id
  }
}
