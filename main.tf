data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  valheim_name  = "tropa-do-calvo"
  valheim_pass  = "curioso"
  valheim_image = "mbround18/valheim:latest"
}


###############################
#             REDE            #
###############################

resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/24"
  enable_dns_hostnames = true
}

resource "aws_subnet" "subnet-a" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "${data.aws_region.current.name}a"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route" "internet_route" {
  route_table_id         = aws_route_table.route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.internet_gateway.id
}

resource "aws_route_table_association" "subnet_route_table_association" {
  route_table_id = aws_route_table.route_table.id
  subnet_id      = aws_subnet.subnet-a.id
}


###############################
#           BUCKET            #
###############################
resource "aws_s3_bucket" "valheim_bucket" {
  bucket = "${local.valheim_name}-bucket"
}

resource "aws_s3_bucket_acl" "valheim_bucket_acl" {
  bucket = aws_s3_bucket.valheim_bucket.id
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "valheim_bucket_versioning" {
  bucket = aws_s3_bucket.valheim_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "valheim_bucket_lifecycle" {
  bucket = aws_s3_bucket.valheim_bucket.id

  rule {
    id     = "rule-1"
    status = "Enabled"
    expiration {
      days = 10
    }
  }
}

###############################
#           HOST              #
###############################

resource "aws_ecs_cluster" "games" {
  name = "Games-Cluster"
}

resource "aws_ecs_cluster_capacity_providers" "providers" {
  cluster_name = aws_ecs_cluster.games.name

  capacity_providers = ["FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 1
    capacity_provider = "FARGATE_SPOT"
  }
}

resource "aws_iam_role" "execution_role" {
  assume_role_policy  = file("iam/role/document_role.json")
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
}

resource "aws_iam_role_policy" "execution_policy" {
  name   = "secrets"
  role   = aws_iam_role.execution_role.id
  policy = file("iam/policy/execution_policy.json")
}

resource "aws_iam_role" "task_role" {
  assume_role_policy  = file("iam/role/document_role.json")
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
}

resource "aws_iam_role_policy" "task_policy" {
  name   = "backups"
  role   = aws_iam_role.task_role.id
  policy = file("iam/policy/task_policy.json")
}

resource "aws_cloudwatch_log_group" "LogGroup" {
  retention_in_days = 3
}

resource "aws_ecs_task_definition" "valheim_ecs_task" {
  family                   = "${local.valheim_name}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "4096"
  execution_role_arn       = aws_iam_role.execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn
  container_definitions = templatefile("container_definitions/valheim-container_definitions.json", {
    valheim_name   = local.valheim_name
    valheim_image  = local.valheim_image
    valheim_pass   = local.valheim_pass
    valheim_bucket = "${local.valheim_name}-bucket"
  })
}

resource "aws_security_group" "security_group" {
  vpc_id = aws_vpc.vpc.id
  ingress {
    from_port   = 2456
    to_port     = 2456
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 2457
    to_port     = 2457
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 2458
    to_port     = 2458
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "TLS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "service" {
  name                   = local.valheim_name
  cluster                = aws_ecs_cluster.games.name
  task_definition        = aws_ecs_task_definition.valheim_ecs_task.id
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true
  network_configuration {
    subnets          = [aws_subnet.subnet-a.id]
    assign_public_ip = true
    security_groups = [
      aws_security_group.security_group.id
    ]
  }
}


###############################
#           LAMBDAS           #
###############################

# data "archive_file" "lambda_start_function_code" {
#   type        = "zip"
#   output_path = "/lambda_start_function_code.zip"
#   source {
#     content  = file("lambdas/valheim_start_server.js")
#     filename = "index.handler"
#   }
# }

# resource "aws_lambda_function" "start_valheim" {
#   function_name    = "${local.valheim_name}-start"
#   runtime          = "nodejs12.x"
#   handler          = "index.handler"
#   memory_size      = 128
#   timeout          = 300
#   filename         = data.archive_file.lambda_start_function_code.output_path
#   source_code_hash = data.archive_file.lambda_start_function_code.output_base64sha256
#   role             = file("iam/role/document_lambda_role.json")
#   environment {
#     variables = {
#       CLUSTER = aws_ecs_service.service.name
#       SERVICE = aws_ecs_cluster.games.id
#       BUCKET  = aws_s3_bucket.valheim_bucket.id
#     }
#   }

# }
