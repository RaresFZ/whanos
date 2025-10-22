pipeline {
    agent any

    options {
        timestamps()
        ansiColor('xterm')
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
    }

    environment {
        REGISTRY_HOST = credentials('whanos-registry-host')
        IMAGE_NAMESPACE = 'whanos/apps'
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
                    env.WHANOS_IMAGE_REF = "${REGISTRY_HOST}/${IMAGE_NAMESPACE}/${repoName}:${appCommit}"
                    env.WHANOS_IMAGE_REF_LATEST = "${REGISTRY_HOST}/${IMAGE_NAMESPACE}/${repoName}:${branchSlug}"
                }
            }
        }

        stage('Build and push image') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'whanos-registry-creds',
                        usernameVariable: 'WHANOS_REGISTRY_USERNAME',
                        passwordVariable: 'WHANOS_REGISTRY_PASSWORD'
                    )
                ]) {
                    script {
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

        stage('Tag latest for branch') {
            steps {
                sh """
                    set -euo pipefail
                    docker tag "\${WHANOS_IMAGE_REF}" "\${WHANOS_IMAGE_REF_LATEST}"
                    docker push "\${WHANOS_IMAGE_REF_LATEST}"
                """
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
            sh 'docker image prune -f || true'
        }
    }
}
