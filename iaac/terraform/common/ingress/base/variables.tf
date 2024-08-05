variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "load_balancer_scheme" {
  description = "Load Balancer Scheme"
  type        = string
  default     = "internal"
}

variable "tags" {
  description = "Additional tags (e.g. `map('BusinessUnit`,`XYZ`)"
  type        = map(string)
  default     = {}
}

variable "certificate_arn" {
  description = "The ARN of ACM"
  type        = string
}

variable "subnet_ids" {
  type        = string
  description = "Subnets for this load balancer"
}