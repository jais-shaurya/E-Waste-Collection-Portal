
pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
        skipDefaultCheckout(false)
    }

    parameters {
        choice(
            name: 'RELEASE_MODE',
            choices: ['STABLE', 'FAULTY_ROLLBACK_DEMO'],
            description: 'Choose a normal release or demonstrate automatic rollback.'
        )
        booleanParam(
            name: 'DEPLOY_TO_KUBERNETES',
            defaultValue: true,
            description: 'Deploy to Docker Desktop Kubernetes after pushing the image.'
        )
    }

    environment {
        DOCKER_IMAGE = 'jaisshaurya/ewaste-portal'
        K8S_DEPLOYMENT = 'ewaste-portal'
        K8S_CONTAINER = 'ewaste-portal'
        K8S_SERVICE = 'ewaste-portal-service'
        K8S_NAMESPACE = 'default'
        K8S_CONTEXT = 'docker-desktop'
        SMOKE_CONTAINER = 'ewaste-portal-smoke'
        SMOKE_PORT = '18082'
    }

    stages {
        stage('Parallel Validation') {
            parallel {
                stage('HTML Smoke Test') {
                    steps {
                        powershell '''
                            $ErrorActionPreference = 'Stop'

                            if (-not (Test-Path 'index.html')) {
                                throw 'Required file missing: index.html'
                            }

                            $html = Get-Content 'index.html' -Raw

                            if ($html -notmatch '(?i)<html') {
                                throw 'index.html does not contain an HTML document.'
                            }

                            if ($html.Length -lt 100) {
                                throw 'index.html appears to be empty or incomplete.'
                            }

                            Write-Output 'HTML source validation passed.'
                        '''
                    }
                }

                stage('Configuration Validation') {
                    steps {
                        powershell '''
                            $ErrorActionPreference = 'Stop'

                            $requiredFiles = @(
                                'Dockerfile',
                                'Jenkinsfile',
                                'deployment.yaml'
                            )

                            foreach ($file in $requiredFiles) {
                                if (-not (Test-Path $file -PathType Leaf)) {
                                    throw "Required file missing: $file"
                                }
                            }

                            $dockerfile = Get-Content 'Dockerfile' -Raw
                            if ($dockerfile -notmatch '(?im)^FROM\\s+nginx:alpine') {
                                throw 'Dockerfile does not use the expected nginx:alpine base image.'
                            }

                            $manifest = Get-Content 'deployment.yaml' -Raw
                            if ($manifest -notmatch '(?m)^kind:\\s*Deployment\\s*$') {
                                throw 'deployment.yaml must contain a Deployment.'
                            }
                            if ($manifest -notmatch '(?m)^kind:\\s*Service\\s*$') {
                                throw 'deployment.yaml must contain a Service.'
                            }

                            Write-Output 'Configuration validation passed.'
                            Write-Output 'README.md is intentionally not required.'
                        '''
                    }
                }
            }
        }

        stage('Build and Test Docker Image') {
            steps {
                powershell '''
                    $ErrorActionPreference = 'Stop'

                    $docker = (Get-Command docker.exe -ErrorAction Stop).Source
                    $imageVersion = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"
                    $imageLatest = "$env:DOCKER_IMAGE`:latest"

                    & $docker build -t $imageVersion -t $imageLatest .
                    if ($LASTEXITCODE -ne 0) {
                        throw 'Docker image build failed.'
                    }

                    Write-Output "Built image: $imageVersion"

                    # Remove an old smoke-test container if it exists.
                    & $docker rm -f $env:SMOKE_CONTAINER 2>$null
                    $LASTEXITCODE = 0

                    try {
                        & $docker run -d --name $env:SMOKE_CONTAINER `
                            -p "$($env:SMOKE_PORT):80" $imageVersion

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not start the Docker smoke-test container.'
                        }

                        Start-Sleep -Seconds 5

                        $response = Invoke-WebRequest `
                            -Uri "http://localhost:$($env:SMOKE_PORT)/" `
                            -UseBasicParsing `
                            -TimeoutSec 20

                        if ($response.StatusCode -ne 200) {
                            throw "Smoke test returned HTTP $($response.StatusCode)."
                        }

                        Write-Output 'Docker container smoke test passed.'
                    }
                    finally {
                        & $docker rm -f $env:SMOKE_CONTAINER 2>$null
                        $LASTEXITCODE = 0
                    }
                '''
            }
        }

        stage('Docker Hub Authentication and Push') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'dockerhub-credentials',
                        usernameVariable: 'DH_USER',
                        passwordVariable: 'DH_TOKEN'
                    )
                ]) {
                    powershell '''
                        $ErrorActionPreference = 'Stop'

                        $docker = (Get-Command docker.exe -ErrorAction Stop).Source
                        $cmd = Join-Path $env:SystemRoot 'System32\\cmd.exe'
                        $authDir = Join-Path $env:WORKSPACE ".docker-auth-$env:BUILD_NUMBER"
                        $tokenFile = Join-Path $authDir 'stdin.txt'
                        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

                        New-Item -ItemType Directory -Path $authDir -Force | Out-Null

                        try {
                            # Write the token without a UTF-8 BOM.
                            [System.IO.File]::WriteAllText(
                                $tokenFile,
                                $env:DH_TOKEN + "`n",
                                $utf8NoBom
                            )

                            # Pass the token through stdin redirection, not the command line.
                            $loginCommand = '"' + $docker +
                                '" --config "' + $authDir +
                                '" login --username "' + $env:DH_USER +
                                '" --password-stdin < "' + $tokenFile + '"'

                            & $cmd /d /s /c $loginCommand
                            if ($LASTEXITCODE -ne 0) {
                                throw 'Docker Hub login failed. Check dockerhub-credentials.'
                            }

                            $imageVersion = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"
                            $imageLatest = "$env:DOCKER_IMAGE`:latest"

                            & $docker --config $authDir push $imageVersion
                            if ($LASTEXITCODE -ne 0) {
                                throw "Failed to push $imageVersion"
                            }

                            & $docker --config $authDir push $imageLatest
                            if ($LASTEXITCODE -ne 0) {
                                throw "Failed to push $imageLatest"
                            }

                            Write-Output 'Both Docker Hub image tags were pushed successfully.'
                        }
                        finally {
                            # Attempt logout and always remove temporary authentication files.
                            & $docker --config $authDir logout 2>$null
                            $LASTEXITCODE = 0

                            Remove-Item -Path $authDir -Recurse -Force `
                                -ErrorAction SilentlyContinue
                        }
                    '''
                }
            }
        }

        stage('Deploy Stable Release') {
            when {
                expression {
                    params.DEPLOY_TO_KUBERNETES &&
                    params.RELEASE_MODE == 'STABLE'
                }
            }
            steps {
                withCredentials([
                    file(
                        credentialsId: 'kubeconfig',
                        variable: 'KUBECONFIG_FILE'
                    )
                ]) {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $env:KUBECONFIG = $env:KUBECONFIG_FILE

                        $context = $env:K8S_CONTEXT
                        $namespace = $env:K8S_NAMESPACE
                        $image = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"

                        & kubectl.exe --context=$context `
                            --namespace=$namespace apply -f deployment.yaml
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Failed to apply deployment.yaml.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace set image `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            "$env:K8S_CONTAINER=$image"
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Failed to update the Kubernetes deployment image.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout status `
                            "deployment/$env:K8S_DEPLOYMENT" --timeout=180s
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Kubernetes rollout failed.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace get deployment,pods,service
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not verify Kubernetes resources.'
                        }

                        Write-Output "Stable deployment succeeded with image $image."
                        Write-Output 'Portal NodePort: http://localhost:30082'
                    '''
                }
            }
        }

        stage('Faulty Rollout and Automatic Rollback') {
            when {
                expression {
                    params.DEPLOY_TO_KUBERNETES &&
                    params.RELEASE_MODE == 'FAULTY_ROLLBACK_DEMO'
                }
            }
            steps {
                withCredentials([
                    file(
                        credentialsId: 'kubeconfig',
                        variable: 'KUBECONFIG_FILE'
                    )
                ]) {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $env:KUBECONFIG = $env:KUBECONFIG_FILE

                        $context = $env:K8S_CONTEXT
                        $namespace = $env:K8S_NAMESPACE

                        # Ensure a valid deployment exists before the rollback demonstration.
                        & kubectl.exe --context=$context `
                            --namespace=$namespace apply -f deployment.yaml
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not apply the initial Kubernetes manifest.'
                        }

                        $stableImage = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"

                        & kubectl.exe --context=$context `
                            --namespace=$namespace set image `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            "$env:K8S_CONTAINER=$stableImage"
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not establish the valid image before the demo.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout status `
                            "deployment/$env:K8S_DEPLOYMENT" --timeout=180s
                        if ($LASTEXITCODE -ne 0) {
                            throw 'The initial valid deployment did not become ready; refusing to run the faulty demo.'
                        }

                        # Deliberately use a nonexistent tag to trigger a failed rollout.
                        $badImage = "$env:DOCKER_IMAGE`:deliberately-missing-tag"

                        & kubectl.exe --context=$context `
                            --namespace=$namespace set image `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            "$env:K8S_CONTAINER=$badImage"
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not apply the intentionally faulty image.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout status `
                            "deployment/$env:K8S_DEPLOYMENT" --timeout=90s

                        $faultyRolloutExit = $LASTEXITCODE

                        if ($faultyRolloutExit -eq 0) {
                            throw 'The intentionally faulty rollout unexpectedly succeeded; rollback demo is inconclusive.'
                        }

                        Write-Output 'Faulty rollout detected. Initiating automatic rollback.'

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout undo `
                            "deployment/$env:K8S_DEPLOYMENT"
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Automatic Kubernetes rollback failed.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout status `
                            "deployment/$env:K8S_DEPLOYMENT" --timeout=180s
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Rollback was issued, but the restored rollout did not become ready.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace get deployment,pods
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not verify resources after rollback.'
                        }

                        Write-Output 'Rollback succeeded. The previous working revision is restored.'
                    '''
                }
            }
        }

        stage('Deployment Skipped') {
            when {
                expression {
                    !params.DEPLOY_TO_KUBERNETES
                }
            }
            steps {
                echo 'Kubernetes deployment was disabled. Image build and Docker Hub push still run.'
            }
        }

        stage('Archive Build Artifacts') {
            steps {
                archiveArtifacts(
                    artifacts: 'index.html,Dockerfile,Jenkinsfile,deployment.yaml',
                    fingerprint: true
                )
            }
        }
    }

    post {
        success {
            echo "E-Waste pipeline completed successfully. Release mode: ${params.RELEASE_MODE}"
        }
        failure {
            echo "E-Waste pipeline failed. Review the first failed stage in Console Output."
        }
        always {
            powershell '''
                $ErrorActionPreference = 'Continue'
                $dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue

                if ($dockerCommand) {
                    & $dockerCommand.Source rm -f $env:SMOKE_CONTAINER 2>$null
                    $LASTEXITCODE = 0
                }

                $authDir = Join-Path $env:WORKSPACE ".docker-auth-$env:BUILD_NUMBER"
                if (Test-Path $authDir) {
                    Remove-Item $authDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            '''
        }
    }
}
