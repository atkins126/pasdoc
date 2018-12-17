/* -*- mode: groovy -*-
  Confgure how to run our job in Jenkins.
  See https://github.com/castle-engine/castle-engine/wiki/Cloud-Builds-(Jenkins) .
  While PasDoc doesn't use Castle Game Engine,
  but it uses CGE Jenkins infrastructure on http://jenkins.castle-engine.io/ ,
  including a Docker image that contains various versions of FPC.
*/

pipeline {
  agent any
  stages {
    stage('Build') {
      agent {
        docker {
          image 'kambi/castle-engine-cloud-builds-tools:cge-none'
        }
      }
      steps {
        sh 'www/snapshots/build.sh'
        stash name: 'snapshots-to-publish', includes: 'pasdoc-*.tar.gz,pasdoc-*zip'
      }
    }
    stage('Upload Snapshots') {
      /* This must run on michalis.ii.uni.wroc.pl, outside Docker,
         since it directly copies the files. */
      agent { label 'web-michalis-ii-uni-wroc-pl' }
      steps {
        unstash name: 'snapshots-to-publish'
        sh 'www/snapshots/upload.sh'
      }
    }
  }
  post {
    success {
      archiveArtifacts artifacts: 'pasdoc-*.tar.gz,pasdoc-*zip'
    }
    regression {
      mail to: 'michalis.kambi@gmail.com',
        subject: "[jenkins] Build started failing: ${currentBuild.fullDisplayName}",
        body: "See the build details on ${env.BUILD_URL}"
    }
    failure {
      mail to: 'michalis.kambi@gmail.com',
        subject: "[jenkins] Build failed: ${currentBuild.fullDisplayName}",
        body: "See the build details on ${env.BUILD_URL}"
    }
    fixed {
      mail to: 'michalis.kambi@gmail.com',
        subject: "[jenkins] Build is again successfull: ${currentBuild.fullDisplayName}",
        body: "See the build details on ${env.BUILD_URL}"
    }
    /* TODO: In the future this should kick rebuild of
       kambi/castle-engine-cloud-builds-tools:cge-none
       since it may include latest PasDoc. */
  }
}
