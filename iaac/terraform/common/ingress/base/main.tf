# Implement ingress in terraform instead of using chart to use features like wait_for_load_balancer
resource "kubernetes_ingress_v1" "istio_ingress" {
  wait_for_load_balancer = true

  metadata {
    annotations = {
      "alb.ingress.kubernetes.io/certificate-arn" = var.certificate_arn
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/ssl-ports" = 443
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
      "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
      "alb.ingress.kubernetes.io/success-codes" = "200-303"
      "alb.ingress.kubernetes.io/subnets" = var.subnet_ids
    }
    name      = "istio-ingress"
    namespace = "istio-system"
  }

  spec {
    ingress_class_name = "alb"
    rule {
      http {
        path {
          path = "/*"
          backend {
            service {
              name = "istio-ingressgateway"
              port {
                number = 80
              }
            }
          }
          path_type = "ImplementationSpecific"
        }
      }
    }
  }
}

# Import by tag because ALB cannot be imported by DNS provided by output of Ingress status
data "aws_lb" "istio_ingress" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "istio-system/istio-ingress"
  }
  depends_on = [
    kubernetes_ingress_v1.istio_ingress
  ]
}