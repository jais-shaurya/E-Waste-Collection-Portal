
pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    parameters {
        choice(
            name: 'RELEASE_MODE',
            choices: ['STABLE', 'FAULTY_ROLLBACK_DEMO'],
            description: 'Stable release or deliberate rollout failure and recovery'
        )
        booleanParam(
            name: 'DEPLOY_TO_KUBERNETES',
            defaultValue: true,
            description: 'Deploy to Docker Desktop Kubernetes'
        )
    }

    environment {
        DOCKER_IMAGE = 'jaisshaurya/ewaste-portal'
        K8S_DEPLOYMENT = 'ewaste-portal'
        K8S_NAMESPACE = 'default'
    }

    stages {
        stage('Parallel Validation') {
            parallel {
                stage('HTML Smoke Test') {
                    steps {
                        powershell '''
                            $ErrorActionPreference = 'Stop'
                            $html = Get-Content -Raw -Path 'index.html'

                            $required = @(
                                'Central Civic Collection Hub',
                                'Northside Resource Centre',
                                'East Market Drop-off Point',
                                'South Municipal Depot',
                                'Westside Battery',
                                'Processing Status Dashboard'
                            )

                            foreach ($item in $required) {
                                if ($html -notlike "*$item*") {
                                    throw "HTML validation failed: missing $item"
                                }
                            }

                            Write-Output 'HTML smoke test passed.'
                        '''
                    }
                }

                stage('Configuration Validation') {
                    steps {
                        powershell '''
                            $ErrorActionPreference = 'Stop'

                            foreach ($file in @(
                                'Dockerfile',
                                'deployment.yaml',
                                'Jenkinsfile',
                                'README.md'
                            )) {
                                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                                    throw "Required file missing: $file"
                                }
                            }

                            $manifest = Get-Content -Raw 'deployment.yaml'

                            if ($manifest -notmatch 'kind: Deployment' -or
                                $manifest -notmatch 'name: ewaste-portal' -or
                                $manifest -notmatch 'nodePort: 30082') {
                                throw 'Kubernetes manifest validation failed.'
                            }

                            Write-Output 'Configuration validation passed.'
                        '''
                    }
                }
            }
        }

        stage('Build and Test Docker Image') {
            when {
                expression { params.RELEASE_MODE == 'STABLE' }
            }
            steps {
                powershell '''
                    $ErrorActionPreference = 'Stop'

                    $dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
                    if (-not $dockerCommand) {
                        throw 'docker.exe not found in Jenkins PATH. Configure Docker CLI access for the Jenkins service.'
                    }

                    $dockerExe = $dockerCommand.Source
                    $env:IMAGE_TAG = "$env:BUILD_NUMBER"

                    & $dockerExe version
                    if ($LASTEXITCODE -ne 0) {
                        throw 'Docker Engine verification failed.'
                    }

                    & $dockerExe build --pull `
                        -t "$env:DOCKER_IMAGE`:$env:IMAGE_TAG" `
                        -t "$env:DOCKER_IMAGE`:latest" .

                    if ($LASTEXITCODE -ne 0) {
                        throw 'Docker image build failed.'
                    }

                    $testName = "ewaste-smoke-$env:BUILD_NUMBER"

                    try {
                        & $dockerExe rm -f $testName 2>$null

                        & $dockerExe run -d `
                            --name $testName `
                            -p 18082:80 `
                            "$env:DOCKER_IMAGE`:$env:IMAGE_TAG"

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not start the local smoke-test container.'
                        }

                        $healthy = $false

                        for ($i = 0; $i -lt 15; $i++) {
                            try {
                                $response = Invoke-WebRequest `
                                    -UseBasicParsing `
                                    -Uri 'http://localhost:18082' `
                                    -TimeoutSec 3

                                if ($response.StatusCode -eq 200 -and
                                    $response.Content -match 'E-Waste Collection') {
                                    $healthy = $true
                                    break
                                }
                            }
                            catch {
                                Start-Sleep -Seconds 2
                            }
                        }

                        if (-not $healthy) {
                            & $dockerExe logs $testName
                            throw 'Local container HTTP smoke test failed.'
                        }

                        Write-Output 'Local container HTTP test passed.'
                    }
                    finally {
                        & $dockerExe rm -f $testName 2>$null
                    }
                '''
            }
        }

        stage('Docker Hub Authentication and Push') {
            when {
                expression { params.RELEASE_MODE == 'STABLE' }
            }
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

                        $dockerCommand = Get-Command docker.exe -ErrorAction Stop
                        $dockerExe = $dockerCommand.Source
                        $cmdExe = Join-Path $env:SystemRoot 'System32\\cmd.exe'

                        $authDir = Join-Path $env:WORKSPACE `
                            ".docker-auth-$env:BUILD_NUMBER"

                        $tokenFile = Join-Path $authDir 'stdin.txt'

                        New-Item -ItemType Directory `
                            -Path $authDir -Force | Out-Null

                        try {
                            $utf8 = New-Object System.Text.UTF8Encoding($false)

                            [System.IO.File]::WriteAllText(
                                $tokenFile,
                                $env:DH_TOKEN + "`n",
                                $utf8
                            )

                            $dockerArgs = '--config "' + $authDir +
                                '" login --username "' + $env:DH_USER +
                                '" --password-stdin < "' + $tokenFile + '"'

                            $cmd = '"' + $dockerExe + '" ' + $dockerArgs

                            & $cmdExe /d /s /c ('"' + $cmd + '"')

                            if ($LASTEXITCODE -ne 0) {
                                throw 'Docker Hub login failed.'
                            }

                            $imageTag = "$env:DOCKER_IMAGE`:$env:BUILD_NUMBER"
                            $latestTag = "$env:DOCKER_IMAGE`:latest"

                            & $dockerExe --config $authDir push $imageTag

                            if ($LASTEXITCODE -ne 0) {
                                throw 'Versioned image push failed.'
                            }

                            & $dockerExe --config $authDir push $latestTag

                            if ($LASTEXITCODE -ne 0) {
                                throw 'Latest image push failed.'
                            }

                            Write-Output 'Docker Hub image pushes succeeded.'
                        }
                        finally {
                            try {
                                & $dockerExe --config $authDir logout
                            }
                            catch {
                                Write-Output 'Docker logout failed; continuing cleanup.'
                            }

                            if (Test-Path -LiteralPath $authDir) {
                                Remove-Item -LiteralPath $authDir `
                                    -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        }
                    '''
                }
            }
        }

        stage('Deploy Stable Release') {
            when {
                allOf {
                    expression { params.RELEASE_MODE == 'STABLE' }
                    expression { params.DEPLOY_TO_KUBERNETES }
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

                        $kubectlCommand = Get-Command kubectl.exe `
                            -ErrorAction SilentlyContinue

                        if (-not $kubectlCommand) {
                            throw 'kubectl.exe not found in Jenkins PATH.'
                        }

                        $kubectlExe = $kubectlCommand.Source
                        $env:KUBECONFIG = $env:KUBECONFIG_FILE

                        & $kubectlExe config current-context
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Cannot determine Kubernetes context.'
                        }

                        & $kubectlExe apply -f deployment.yaml
                        if ($LASTEXITCODE -ne 0) {
                            throw 'Applying Kubernetes manifest failed.'
                        }

                        & $kubectlExe set image `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            "web=$env:DOCKER_IMAGE`:$env:BUILD_NUMBER" `
                            -n $env:K8S_NAMESPACE

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Updating the Deployment image failed.'
                        }

                        & $kubectlExe rollout status `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            -n $env:K8S_NAMESPACE `
                            --timeout=150s

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Stable Kubernetes rollout failed.'
                        }

                        & $kubectlExe get deployment `
                            $env:K8S_DEPLOYMENT -n $env:K8S_NAMESPACE

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not verify Deployment status.'
                        }

                        & $kubectlExe get pods `
                            -l 'app=ewaste-portal' `
                            -n $env:K8S_NAMESPACE

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not verify application pods.'
                        }
                    '''
                }
            }
        }

        stage('Faulty Rollout and Automatic Rollback') {
            when {
                allOf {
                    expression {
                        params.RELEASE_MODE == 'FAULTY_ROLLBACK_DEMO'
                    }
                    expression { params.DEPLOY_TO_KUBERNETES }
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

                        $kubectlCommand = Get-Command kubectl.exe `
                            -ErrorAction SilentlyContinue

                        if (-not $kubectlCommand) {
                            throw 'kubectl.exe not found in Jenkins PATH.'
                        }

                        $kubectlExe = $kubectlCommand.Source
                        $env:KUBECONFIG = $env:KUBECONFIG_FILE

                        & $kubectlExe rollout history `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            -n $env:K8S_NAMESPACE

                        if ($LASTEXITCODE -ne 0) {
                            throw 'No readable rollout history. Deploy a stable release first.'
                        }

                        & $kubectlExe set image `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            "web=$env:DOCKER_IMAGE`:deliberately-missing-tag" `
                            -n $env:K8S_NAMESPACE

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not set the deliberately faulty image.'
                        }

                        $rolloutFailed = $false

                        & $kubectlExe rollout status `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            -n $env:K8S_NAMESPACE `
                            --timeout=45s

                        if ($LASTEXITCODE -ne 0) {
                            $rolloutFailed = $true
                            Write-Output 'Faulty rollout detected. Starting rollback.'
                        }

                        if (-not $rolloutFailed) {
                            throw 'Faulty rollout unexpectedly succeeded. Verify that the missing image tag does not exist.'
                        }

                        & $kubectlExe rollout undo `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            -n $env:K8S_NAMESPACE

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Rollback command failed.'
                        }

                        & $kubectlExe rollout status `
                            "deployment/$env:K8S_DEPLOYMENT" `
                            -n $env:K8S_NAMESPACE `
                            --timeout=150s

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Restored rollout did not become healthy.'
                        }

                        & $kubectlExe get deployment `
                            $env:K8S_DEPLOYMENT -n $env:K8S_NAMESPACE

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not verify Deployment after rollback.'
                        }

                        & $kubectlExe get pods `
                            -l 'app=ewaste-portal' `
                            -n $env:K8S_NAMESPACE

                        if ($LASTEXITCODE -ne 0) {
                            throw 'Could not verify pods after rollback.'
                        }
                    '''
                }
            }
        }

        stage('Archive Build Artifacts') {
            steps {
                archiveArtifacts(
                    artifacts: 'index.html,Dockerfile,Jenkinsfile,deployment.yaml,README.md',
                    allowEmptyArchive: true,
                    fingerprint: true
                )
            }
        }
    }

    post {
        always {
            echo "E-Waste pipeline completed: ${params.RELEASE_MODE}"

            powershell '''
                $authDir = Join-Path $env:WORKSPACE `
                    ".docker-auth-$env:BUILD_NUMBER"

                if (Test-Path -LiteralPath $authDir) {
                    Remove-Item -LiteralPath $authDir `
                        -Recurse -Force -ErrorAction SilentlyContinue
                }
            '''
        }
    }
}
