pipeline {
    agent any

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '25', daysToKeepStr: '14', artifactNumToKeepStr: '5'))
    }

    parameters {
        string(
            name: 'APP_REPOSITORY',
            defaultValue: '',
            description: 'Git clone URL of the Whanos-compatible application repository.'
        )
        string(
            name: 'APP_BRANCH',
            defaultValue: 'main',
            description: 'Git branch or ref of the application repository to build.'
        )
        booleanParam(
            name: 'SKIP_TESTS',
            defaultValue: false,
            description: 'Skip the automated test phase prior to building.'
        )
        text(
            name: 'ADDITIONAL_BUILD_ARGS',
            defaultValue: '',
            description: 'Optional newline-separated Docker build args in KEY=VALUE form.'
        )
        string(
            name: 'REGISTRY_HOST',
            defaultValue: 'registry.whanos.example.com',
            description: 'Registry host. Override if needed.'
        )
    }

    environment {
        IMAGE_NAMESPACE = 'whanos/apps'
        REGISTRY_HOST = "${params.REGISTRY_HOST?.trim() ?: env.GLOBAL_REGISTRY_HOST ?: 'registry.whanos.example.com'}"
    }

    stages {
        stage('Checkout infrastructure repo') {
            steps {
                checkout scm
            }
        }

        stage('Fetch application repository') {
            steps {
                script {
                    if (!params.APP_REPOSITORY?.trim()) {
                        error('APP_REPOSITORY must be provided.')
                    }
                }
                dir('app') {
                    checkout([
                        $class: 'GitSCM',
                        branches: [[name: params.APP_BRANCH]],
                        userRemoteConfigs: [[url: params.APP_REPOSITORY]]
                    ])
                }
            }
        }

        stage('Resolve image reference') {
            steps {
                script {
                    def repoName = params.APP_REPOSITORY
                        .tokenize('/')
                        .last()
                        .replaceAll(/\.git$/, '')
                    def branchSlug = params.APP_BRANCH.replaceAll('[^A-Za-z0-9_.-]+', '-')
                    def appCommit = dir('app') {
                        sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
                    }
                    if (!env.REGISTRY_HOST?.trim()) {
                        error("REGISTRY_HOST is not defined. Provide the pipeline parameter or configure Jenkins global env GLOBAL_REGISTRY_HOST.")
                    }
                    env.WHANOS_IMAGE_REF = "${env.REGISTRY_HOST}/${IMAGE_NAMESPACE}/${repoName}:${appCommit}"
                    env.WHANOS_IMAGE_REF_LATEST = "${env.REGISTRY_HOST}/${IMAGE_NAMESPACE}/${repoName}:${branchSlug}"
                }
            }
        }

        stage('Build and push image') {
            steps {
                ansiColor('xterm') {
                    script {
                        def buildxAvailable = (sh(script: "docker buildx version >/dev/null 2>&1", returnStatus: true) == 0)
                        if (!buildxAvailable) {
                            echo "Buildx not available; building with classic docker builder."
                        }
                        def buildEnv = buildxAvailable ? ['DOCKER_BUILDKIT=1'] : []
                        withCredentials([
                            usernamePassword(
                                credentialsId: 'whanos-registry-creds',
                                usernameVariable: 'WHANOS_REGISTRY_USERNAME',
                                passwordVariable: 'WHANOS_REGISTRY_PASSWORD'
                            )
                        ]) {
                            withEnv(buildEnv) {
                                def shellQuote = { String value ->
                                    if (!value) {
                                        return "''"
                                    }
                                    return "'" + value.replace("'", "'\"'\"'") + "'"
                                }

                                def additionalArgs = params.ADDITIONAL_BUILD_ARGS
                                    .split("\\r?\\n")
                                    .findAll { it?.trim() }
                                    .collect { it.trim() }

                                def commandParts = [
                                    "python3",
                                    "orchestrator/main.py",
                                    "--repo ${shellQuote("${WORKSPACE}/app")}",
                                    "--image ${shellQuote(env.WHANOS_IMAGE_REF)}",
                                    "--registry ${shellQuote(env.REGISTRY_HOST)}"
                                ]

                                if (params.SKIP_TESTS) {
                                    commandParts << "--skip-tests"
                                }

                                additionalArgs.each { value ->
                                    commandParts << "--build-arg ${shellQuote(value)}"
                                }

                                def command = commandParts.join(" \\\n                              ")

                                sh """
                                    set -euo pipefail
                                    ${command}
                                """
                            }
                        }
                    }
                }
            }
        }

        stage('Tag latest for branch') {
            steps {
                ansiColor('xterm') {
                    sh """
                        set -euo pipefail
                        docker tag "\${WHANOS_IMAGE_REF}" "\${WHANOS_IMAGE_REF_LATEST}"
                        docker push "\${WHANOS_IMAGE_REF_LATEST}"
                    """
                }
            }
        }
    }

    post {
        success {
            echo "✅ Whanos build success: ${env.WHANOS_IMAGE_REF}"
        }
        failure {
            echo "❌ Whanos build failed. Inspect the stage logs."
        }
        cleanup {
            ansiColor('xterm') {
                sh 'docker image prune -f || true'
            }
        }
    }
}
