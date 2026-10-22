
pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    parameters {
        choice(
            name: 'RELEASE_MODE',
            choices: ['STABLE', 'FAULTY_ROLLBACK_DEMO'],
            description: 'Choose a stable deployment or demonstrate automatic rollback.'
        )
        booleanParam(
            name: 'DEPLOY_TO_KUBERNETES',
            defaultValue: true,
            description: 'Deploy the image to Docker Desktop Kubernetes.'
        )
    }

    environment {
        DOCKER_IMAGE = 'jaisshaurya/ewaste-portal'
        K8S_DEPLOYMENT = 'ewaste-portal'
        K8S_CONTAINER = 'ewaste-portal'
        K8S_SERVICE = 'ewaste-portal-service'
        K8S_NAMESPACE = 'default'
        K8S_CONTEXT = 'docker-desktop'
        K8S_NODE_PORT = '30086'
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

                            if (-not (Test-Path 'index.html' -PathType Leaf)) {
                                throw 'Required file missing: index.html'
                            }

                            $html = Get-Content 'index.html' -Raw

                            if ($html -notmatch '(?i)<html') {
                                throw 'index.html does not contain an HTML document.'
                            }

                            if ($html.Length -lt 100) {
                                throw 'index.html appears incomplete.'
                            }

                            Write-Output 'HTML validation passed.'
                        '''
                    }
                }

                stage('Configuration Validation') {
                    steps {
                        powershell '''
                            $ErrorActionPreference = 'Stop'

                            foreach ($file in @(
                                'Dockerfile',
                                'Jenkinsfile',
                                'deployment.yaml'
                            )) {
                                if (-not (Test-Path $file -PathType Leaf)) {
                                    throw "Required file missing: $file"
                                }
                            }

                            $dockerfile = Get-Content 'Dockerfile' -Raw
                            if ($dockerfile -notmatch '(?im)^FROM\\s+nginx:alpine') {
                                throw 'Expected nginx:alpine in Dockerfile.'
                            }

                            $manifest = Get-Content 'deployment.yaml' -Raw

                            if ($manifest -notmatch '(?m)^kind:\\s*Deployment\\s*$') {
                                throw 'deployment.yaml must contain a Deployment.'
                            }

                            if ($manifest -notmatch '(?m)^kind:\\s*Service\\s*$') {
                                throw 'deployment.yaml must contain a Service.'
                            }

                            if ($manifest -notmatch '(?m)^\\s*nodePort:\\s*30086\\s*$') {
                                throw 'Expected Service NodePort 30086.'
                            }

                            Write-Output 'Configuration validation passed.'
                            Write-Output 'README.md is not required.'
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
                    $versionImage = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"
                    $latestImage = "$env:DOCKER_IMAGE`:latest"

                    & $docker build -t $versionImage -t $latestImage .
                    if ($LASTEXITCODE -ne 0) {
                        throw 'Docker image build failed.'
                    }

                    & $docker rm -f $env:SMOKE_CONTAINER 2>$null
                    $LASTEXITCODE = 0

                    try {
                        & $docker run -d `
                            --name $env:SMOKE_CONTAINER `
                            -p "$($env:SMOKE_PORT):80" `
                            $versionImage

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not start the smoke-test container.'
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
                            [System.IO.File]::WriteAllText(
                                $tokenFile,
                                $env:DH_TOKEN + "`n",
                                $utf8NoBom
                            )

                            $loginCommand = '"' + $docker +
                                '" --config "' + $authDir +
                                '" login --username "' + $env:DH_USER +
                                '" --password-stdin < "' + $tokenFile + '"'

                            & $cmd /d /s /c $loginCommand

                            if ($LASTEXITCODE -ne 0) {
                                throw 'Docker Hub login failed. Check dockerhub-credentials.'
                            }

                            $versionImage = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"
                            $latestImage = "$env:DOCKER_IMAGE`:latest"

                            & $docker --config $authDir push $versionImage
                            if ($LASTEXITCODE -ne 0) {
                                throw "Failed to push $versionImage"
                            }

                            & $docker --config $authDir push $latestImage
                            if ($LASTEXITCODE -ne 0) {
                                throw "Failed to push $latestImage"
                            }

                            Write-Output 'Both Docker Hub image tags pushed successfully.'
                        }
                        finally {
                            & $docker --config $authDir logout 2>$null
                            $LASTEXITCODE = 0

                            Remove-Item $authDir -Recurse -Force `
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
                        credentialsId: 'kubeconfig-global',
                        variable: 'KUBECONFIG_FILE'
                    )
                ]) {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $env:KUBECONFIG = $env:KUBECONFIG_FILE

                        $versionImage = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"

                        & kubectl.exe --context=$env:K8S_CONTEXT `
                            --namespace=$env:K8S_NAMESPACE `
                            apply -f deployment.yaml

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Applying deployment.yaml failed. Check the NodePort and manifest.'
                        }

                        & kubectl.exe --context=$env:K8S_CONTEXT `
                            --namespace=$env:K8S_NAMESPACE `
                            set image "deployment/$env:K8S_DEPLOYMENT" `
                            "$env:K8S_CONTAINER=$versionImage"

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Updating the Kubernetes image failed.'
                        }

                        & kubectl.exe --context=$env:K8S_CONTEXT `
                            --namespace=$env:K8S_NAMESPACE `
                            rollout status "deployment/$env:K8S_DEPLOYMENT" `
                            --timeout=180s

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Kubernetes rollout failed.'
                        }

                        & kubectl.exe --context=$env:K8S_CONTEXT `
                            --namespace=$env:K8S_NAMESPACE `
                            get deployment,pods,service

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Kubernetes resource verification failed.'
                        }

                        Write-Output "Deployment succeeded with image $versionImage."
                        Write-Output 'Portal URL: http://localhost:30086'
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
                        credentialsId: 'kubeconfig-global',
                        variable: 'KUBECONFIG_FILE'
                    )
                ]) {
                    powershell '''
                        $ErrorActionPreference = 'Stop'
                        $env:KUBECONFIG = $env:KUBECONFIG_FILE

                        $context = $env:K8S_CONTEXT
                        $namespace = $env:K8S_NAMESPACE
                        $deployment = "deployment/$env:K8S_DEPLOYMENT"

                        & kubectl.exe --context=$context `
                            --namespace=$namespace apply -f deployment.yaml

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Applying the Kubernetes manifest failed.'
                        }

                        $validImage = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"

                        & kubectl.exe --context=$context `
                            --namespace=$namespace set image $deployment `
                            "$env:K8S_CONTAINER=$validImage"

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Setting the valid image failed.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout status $deployment `
                            --timeout=180s

                        if ($LASTEXITCODE -ne 0) {
                            throw 'The valid deployment did not become ready.'
                        }

                        $badImage = "$env:DOCKER_IMAGE`:deliberately-missing-tag"

                        & kubectl.exe --context=$context `
                            --namespace=$namespace set image $deployment `
                            "$env:K8S_CONTAINER=$badImage"

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not apply the deliberately faulty image.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout status $deployment `
                            --timeout=90s

                        $faultyExit = $LASTEXITCODE

                        if ($faultyExit -eq 0) {
                            throw 'The deliberately faulty rollout unexpectedly succeeded.'
                        }

                        Write-Output 'Faulty rollout detected. Starting automatic rollback.'

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout undo $deployment

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Kubernetes rollback command failed.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace rollout status $deployment `
                            --timeout=180s

                        if ($LASTEXITCODE -ne 0) {
                            throw 'The restored deployment did not become ready.'
                        }

                        & kubectl.exe --context=$context `
                            --namespace=$namespace get deployment,pods

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not verify the rollback.'
                        }

                        Write-Output 'Rollback completed and rollout is healthy.'
                    '''
                }
            }
        }

        stage('Deployment Skipped') {
            when {
                expression { !params.DEPLOY_TO_KUBERNETES }
            }
            steps {
                echo 'Kubernetes deployment disabled; image build and push still run.'
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
            echo "E-Waste pipeline completed successfully: ${params.RELEASE_MODE}"
        }

        failure {
            echo 'E-Waste pipeline failed. Review the first failed stage in Console Output.'
        }

        always {
            powershell '''
                $ErrorActionPreference = 'Continue'

                $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
                if ($docker) {
                    & $docker.Source rm -f $env:SMOKE_CONTAINER 2>$null
                    $LASTEXITCODE = 0
                }

                $authDir = Join-Path $env:WORKSPACE ".docker-auth-$env:BUILD_NUMBER"
                if (Test-Path $authDir) {
                    Remove-Item $authDir -Recurse -Force `
                        -ErrorAction SilentlyContinue
                }
            '''
        }
    }
}
