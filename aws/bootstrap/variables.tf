# Variables in alphabetical order (HashiCorp Style Guide).

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names. Match what the main module uses."
  default     = "nwm-ngencerf"
}

variable "region" {
  type        = string
  description = "AWS region for the state backend."
  default     = "us-east-1"
}
