terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>4.0"
    }
  }
  backend "s3" {
    bucket = "absquare-buck"
    key    = "aws/bahms-money/terraform.tfstate"
    region = "eu-north-1"
  }
}

provider "aws" {
  region = "us-east-1"
}





# Data source declaration for all necessary fetch
data "aws_vpc" "default_vpc" {
  default = true
}

data "aws_subnets" "subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default_vpc.id]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  owners = ["099720109477"] # Canonical
}

data "template_file" "nginx_data_script" {
  template = file("./user-data.tpl")
  vars = {
    server = "nginx"
  }
}

data "template_file" "apache_data_script" {
  template = file("./user-data.tpl")
  vars = {
    server = "apache2"
  }
}


# General Security group declaration
resource "aws_security_group" "terraform-sg" {
  egress = [{
    cidr_blocks      = ["0.0.0.0/0"]
    description      = ""
    from_port        = 0
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "-1"
    security_groups  = []
    self             = false
    to_port          = 0
  }]

  ingress = [{
    cidr_blocks      = ["0.0.0.0/0"]
    description      = "allow ssh"
    from_port        = 22
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups  = []
    self             = false
    to_port          = 22
    },
    {
      cidr_blocks      = ["0.0.0.0/0"]
      description      = "allow http"
      from_port        = 80
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      protocol         = "tcp"
      security_groups  = []
      self             = false
      to_port          = 80
    },
    {
      cidr_blocks      = ["0.0.0.0/0"]
      description      = "allow 5000"
      from_port        = 5000
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      protocol         = "tcp"
      security_groups  = []
      self             = false
      to_port          = 5000
  }]
}

# Provision the ec2 instance for APACHE
resource "aws_instance" "apache-server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  key_name               = "memorykeypair"
  vpc_security_group_ids = [aws_security_group.terraform-sg.id]
  user_data              = base64encode(data.template_file.apache_data_script.rendered)

  tags = {
    "Name" = "apache-server"
  }
}

# Load balancer, Target Group and ASG Declaration

# Load Balancers and component declaration
resource "aws_lb_target_group" "terraform-tg" {
  name        = "terraform-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.aws_vpc.default_vpc.id

  health_check {
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    enabled             = true
  }
}

resource "aws_lb" "terraform-lb" {
  name               = "terraform-lb"
  ip_address_type    = "ipv4"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.terraform-sg.id]
  subnets            = data.aws_subnets.subnets.ids
}

resource "aws_lb_listener" "terraform-lbl" {
  load_balancer_arn = aws_lb.terraform-lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.terraform-tg.arn
  }
}

resource "aws_lb_target_group_attachment" "apache-server" {
  target_group_arn = aws_lb_target_group.terraform-tg.arn
  target_id        = aws_instance.apache-server.id
  port             = 80
}

# ASG and component declaretion
resource "aws_launch_template" "nginx-lt" {
  name                   = "nginx-lt"
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  key_name               = "memorykeypair"
  vpc_security_group_ids = [aws_security_group.terraform-sg.id]
  user_data              = base64encode(data.template_file.nginx_data_script.rendered)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name : "nginx-lt"
    }
  }
}

resource "aws_autoscaling_group" "terraform-asg" {
  name                      = "terraform-asg"
  vpc_zone_identifier       = aws_lb.terraform-lb.subnets
  max_size                  = 10
  min_size                  = 2
  desired_capacity          = 2
  health_check_grace_period = 300
  health_check_type         = "ELB"
  target_group_arns         = [aws_lb_target_group.terraform-tg.arn]

  launch_template {
    id      = aws_launch_template.nginx-lt.id
    version = "$Latest"
  }
}
