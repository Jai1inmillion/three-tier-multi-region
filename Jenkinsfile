pipeline {
  agent any

  parameters {
    // You already use "Pipeline script from SCM", so these are optional.
    // I keep them for flexibility if you ever run this as a freestyle pipeline.
    string(name: 'GIT_URL',    defaultValue: 'https://github.com/Jai1inmillion/three-tier-multi-region.git', description: 'Repo with Terraform code')
    string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch')

    // Infrastructure parameters
    string(name: 'DOMAIN_NAME',      defaultValue: 'cakesstreet.com', description: 'Public hosted zone in Route 53')
    string(name: 'RECORD_NAME',      defaultValue: 'app',             description: 'DNS label (app -> app.cakesstreet.com)')
    string(name: 'PRIMARY_REGION',   defaultValue: 'us-east-2',       description: 'Primary region')
    string(name: 'SECONDARY_REGION', defaultValue: 'us-east-1',       description: 'Secondary region')
    string(name: 'ALERT_EMAIL',      defaultValue: 'jaihanspal@gmail.com', description: 'SNS email')
     
    booleanParam(name: 'AUTO_APPLY', defaultValue: true, description: 'If false, require manual approval before apply')
  }

  environment {
    TF_IN_AUTOMATION = '1'
    TF_VERSION       = '1.13.3'
    // Pass params to Terraform variables
    TF_VAR_primary_region   = "${params.PRIMARY_REGION}"
    TF_VAR_secondary_region = "${params.SECONDARY_REGION}"
    TF_VAR_domain_name      = "${params.DOMAIN_NAME}"
    TF_VAR_record_name      = "${params.RECORD_NAME}"
    TF_VAR_alert_email      = "${params.ALERT_EMAIL}"
  }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    skipDefaultCheckout(true)   // we'll do 'checkout scm' ourselves
  }

  stages {
    stage('Checkout') {
      steps {
        // Works perfectly because your job is "Pipeline script from SCM"
        checkout scm
        sh 'git log -1 --oneline || true'
      }
    }

    stage('Install Terraform (Ubuntu)') {
      steps {
        sh '''
          set -eux
          mkdir -p .tfbin

          # Ensure unzip is present (Ubuntu)
          if ! command -v unzip >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            sudo apt-get update
            sudo apt-get install -y unzip
          fi

          # Download & install pinned Terraform
          if [ ! -x ".tfbin/terraform" ] || [ "$(.tfbin/terraform version -json | jq -r .terraform_version || echo 0)" != "${TF_VERSION}" ]; then
            curl -fsSLo .tfbin/terraform.zip "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
            unzip -o .tfbin/terraform.zip -d .tfbin
            chmod +x .tfbin/terraform
          fi

          ./.tfbin/terraform -version
        '''
      }
    }

    stage('Create terraform.auto.tfvars') {
      steps {
        withCredentials([
          // Create this Jenkins credential: Kind=Secret text, ID=rds-db-password
          string(credentialsId: 'rds-db-password', variable: 'DB_PASS')
          // If you do NOT use an EC2 Instance Profile on the Jenkins node,
          // also add AWS credentials here and export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_DEFAULT_REGION.
        ]) {
          sh '''
            set -eux
            cat > terraform.auto.tfvars <<EOF
            primary_region   = "${PRIMARY_REGION}"
            secondary_region = "${SECONDARY_REGION}"
            domain_name      = "${DOMAIN_NAME}"
            record_name      = "${RECORD_NAME}"
            alert_email      = "${ALERT_EMAIL}"
            db_username      = "admin"
            EOF
            echo "=== terraform.auto.tfvars ==="
            cat terraform.auto.tfvars
          '''
        }
      }
    }

    stage('Terraform Init') {
      steps {
        withEnv(["PATH+TF=${WORKSPACE}/.tfbin"]) {
          sh 'terraform init -input=false'
        }
      }
    }

    stage('Validate & Plan') {
      steps {
        withEnv(["PATH+TF=${WORKSPACE}/.tfbin"]) {
          withCredentials([ string(credentialsId: 'rds-db-password', variable: 'TF_VAR_db_password') ]){
          sh '''
            set -eux
            terraform validate
            terraform plan -input=false -out=tfplan.bin
            terraform show -no-color tfplan.bin > tfplan.txt
          '''
        }
        }
      }
      post {
        always {
          archiveArtifacts artifacts: 'tfplan.bin, tfplan.txt, terraform.auto.tfvars', fingerprint: true
        }
      }
    }

    stage('Approval (if AUTO_APPLY=false)') {
      when { expression { !params.AUTO_APPLY } }
      steps {
        input message: "Apply this plan to ${params.DOMAIN_NAME}?", ok: 'Apply'
      }
    }

    stage('Apply') {
      steps {
        withEnv(["PATH+TF=${WORKSPACE}/.tfbin"]) {
          sh 'terraform apply -input=false -auto-approve tfplan.bin'
        }
      }
    }

    stage('Outputs') {
      steps {
        withEnv(["PATH+TF=${WORKSPACE}/.tfbin"]) {
          sh '''
            set -eux
            terraform output -json > tfoutputs.json
            echo "==== Terraform Outputs (human) ===="
            terraform output || true
          '''
        }
      }
      post {
        always {
          archiveArtifacts artifacts: 'tfoutputs.json', fingerprint: true
        }
      }
    }
  }

  post {
    success {
      echo "Success! Confirm SNS email subscriptions and upload your web/app code to S3."
    }
    failure {
      echo "Failed. Check the console log and plan/artifacts."
    }
  }
}
