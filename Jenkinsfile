pipeline {
  agent any

  parameters {
    string( name: 'GIT_URL',    defaultValue: 'https://github.com/your-org/your-repo.git', description: 'Repo with Terraform code' )
    string( name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch to build' )

    // Infra params (defaults set for your case)
    string( name: 'DOMAIN_NAME',      defaultValue: 'cakesstreet.com', description: 'Public hosted zone in Route 53' )
    string( name: 'RECORD_NAME',      defaultValue: 'app',             description: 'DNS label, e.g., app => app.cakesstreet.com' )
    string( name: 'PRIMARY_REGION',   defaultValue: 'us-east-2',       description: 'Primary AWS region' )
    string( name: 'SECONDARY_REGION', defaultValue: 'us-east-1',       description: 'Secondary AWS region' )
    string( name: 'ALERT_EMAIL',      defaultValue: 'jaihanspal@gmail.com', description: 'SNS email for alerts' )

    booleanParam(name: 'AUTO_APPLY', defaultValue: true, description: 'If false, require manual approval before apply')
  }

  environment {
    TF_IN_AUTOMATION = '1'
    TF_VERSION       = '1.6.6'     // Pin Terraform (change if you prefer)
    // Pass Jenkins params as TF vars (providers and modules read these)
    TF_VAR_primary_region   = "${params.PRIMARY_REGION}"
    TF_VAR_secondary_region = "${params.SECONDARY_REGION}"
    TF_VAR_domain_name      = "${params.DOMAIN_NAME}"
    TF_VAR_record_name      = "${params.RECORD_NAME}"
    TF_VAR_alert_email      = "${params.ALERT_EMAIL}"
  }

  options {
    timestamps()
    ansiColor('xterm')
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  stages {
    stage('Checkout') {
      steps {
        deleteDir()
        git url: params.GIT_URL, branch: params.GIT_BRANCH
        sh 'ls -la'
      }
    }

    stage('Install Terraform (if missing)') {
      steps {
        sh '''
          set -eux
          if ! command -v terraform >/dev/null 2>&1; then
            echo "Terraform not found; installing ${TF_VERSION}..."
            curl -fsSLo terraform.zip https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip
            unzip -o terraform.zip
            sudo mv terraform /usr/local/bin/
            rm -f terraform.zip
          fi
          terraform -version
        '''
      }
    }

    stage('Write terraform.auto.tfvars') {
      steps {
        withCredentials([
          // Create this as a Secret Text in Jenkins with ID 'rds-db-password'
          string(credentialsId: 'rds-db-password', variable: 'DB_PASS')
          // If you AREN'T using an EC2 instance profile on the Jenkins node,
          // also add AWS credentials here with the AWS Credentials plugin
          // and export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_DEFAULT_REGION.
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
            db_password      = "${DB_PASS}"
            EOF
            echo "==== terraform.auto.tfvars ===="
            cat terraform.auto.tfvars
          '''
        }
      }
    }

    stage('Terraform Init') {
      steps {
        sh '''
          set -eux
          terraform init -input=false
        '''
      }
    }

    stage('Validate & Plan') {
      steps {
        sh '''
          set -eux
          terraform fmt -recursive
          terraform validate
          terraform plan -input=false -out=tfplan.bin
          terraform show -no-color tfplan.bin > tfplan.txt
        '''
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
        input message: "Apply this plan to ${params.DOMAIN_NAME}?", ok: 'Apply now'
      }
    }

    stage('Apply') {
      steps {
        sh '''
          set -eux
          terraform apply -input=false -auto-approve tfplan.bin
        '''
      }
    }

    stage('Outputs') {
      steps {
        sh '''
          set -eux
          terraform output -json > tfoutputs.json
          echo "==== Terraform Outputs ===="
          terraform output || true
        '''
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
      echo "Success! Confirm SNS email subscriptions and upload your app/web code to S3."
    }
    failure {
      echo "Provisioning failed — check the console log and the archived plan."
    }
  }
}
