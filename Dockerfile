FROM python:3.8-slim-buster as java-builder

ARG TARGETOS
ARG TARGETARCH

# Install final dependencies
RUN apt-get update && \
        apt-get install -y --no-install-recommends \
        openjdk-11-jdk-headless && \
        apt-get clean && rm -rf /var/lib/apt/lists/*

SHELL [ "/bin/bash", "-c" ]

ENV JAVA_HOME /usr/lib/jvm/java-11-openjdk-${TARGETARCH}
# create a custom, minimized JRE via jlink
RUN jlink --add-modules \
# include required modules
java.base,java.desktop,java.instrument,java.management,java.naming,java.scripting,java.sql,java.xml,jdk.compiler,\
# jdk.unsupported contains sun.misc.Unsafe which is required by certain dependencies
jdk.unsupported,\
# add additional cipher suites
jdk.crypto.cryptoki,\
# add ability to open ZIP/JAR files
jdk.zipfs,\
# Elasticsearch 7+ crashes without Thai Segmentation support
jdk.localedata --include-locales en,th \
    --compress 2 --strip-debug --no-header-files --no-man-pages --output /usr/lib/jvm/java-11 && \
  cp ${JAVA_HOME}/bin/javac /usr/lib/jvm/java-11/bin/javac && \
  cp -r ${JAVA_HOME}/include /usr/lib/jvm/java-11/include && \
  mv /usr/lib/jvm/java-11/lib/modules /usr/lib/jvm/java-11/lib/modules.bk; \
  cp -r ${JAVA_HOME}/lib/* /usr/lib/jvm/java-11/lib/; \
  mv /usr/lib/jvm/java-11/lib/modules.bk /usr/lib/jvm/java-11/lib/modules; \
  rm -rf /usr/bin/java ${JAVA_HOME} && ln -s /usr/lib/jvm/java-11/bin/java /usr/bin/java



FROM python:3.8-slim-buster as base

ARG TARGETOS
ARG TARGETARCH

ARG LOCALSTACK_BUILD_DATE
ARG LOCALSTACK_BUILD_GIT_HASH

ENV LOCALSTACK_BUILD_DATE=${LOCALSTACK_BUILD_DATE}
ENV LOCALSTACK_BUILD_GIT_HASH=${LOCALSTACK_BUILD_GIT_HASH}

LABEL authors="LocalStack Contributors"
LABEL maintainer="Waldemar Hummer (waldemar.hummer@gmail.com)"
LABEL description="LocalStack Docker image"

# Install final dependencies
RUN apt-get update && \
        # Setup Node 14 Dependencies
        apt-get install -y --no-install-recommends curl && \
        curl -sL https://deb.nodesource.com/setup_14.x | bash - && \
        # Install Packages
        apt-get update && \
        apt-get install -y --no-install-recommends \
        git make nodejs openssl tar pixz zip unzip && \
        apt-get clean && rm -rf /var/lib/apt/lists/*

SHELL [ "/bin/bash", "-c" ]

# Install Java 11
ENV LANG C.UTF-8
RUN { \
        echo '#!/bin/sh'; echo 'set -e'; echo; \
        echo 'dirname "$(dirname "$(readlink -f "$(which javac || which java)")")"'; \
    } > /usr/local/bin/docker-java-home \
    && chmod +x /usr/local/bin/docker-java-home


COPY --from=java-builder /usr/lib/jvm/java-11 /usr/lib/jvm/java-11
COPY --from=java-builder /etc/ssl/certs/java /etc/ssl/certs/java
COPY --from=java-builder /etc/java-11-openjdk/security /etc/java-11-openjdk/security
RUN ln -s /usr/lib/jvm/java-11/bin/java /usr/bin/java
ENV JAVA_HOME /usr/lib/jvm/java-11
ENV PATH "${PATH}:${JAVA_HOME}/bin"

# Install Maven - taken from official repo:
# https://github.com/carlossg/docker-maven/blob/master/openjdk-11/Dockerfile)
ARG MAVEN_VERSION=3.6.3
ARG USER_HOME_DIR="/root"
ARG SHA=26ad91d751b3a9a53087aefa743f4e16a17741d3915b219cf74112bf87a438c5
ARG BASE_URL=https://apache.osuosl.org/maven/maven-3/${MAVEN_VERSION}/binaries
RUN mkdir -p /usr/share/maven /usr/share/maven/ref \
  && curl -fsSL -o /tmp/apache-maven.tar.gz ${BASE_URL}/apache-maven-$MAVEN_VERSION-bin.tar.gz \
  && echo "${SHA}  /tmp/apache-maven.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/apache-maven.tar.gz -C /usr/share/maven --strip-components=1 \
  && rm -f /tmp/apache-maven.tar.gz \
  && ln -s /usr/share/maven/bin/mvn /usr/bin/mvn
ENV MAVEN_HOME /usr/share/maven
ENV MAVEN_CONFIG "$USER_HOME_DIR/.m2"
ADD https://raw.githubusercontent.com/carlossg/docker-maven/master/openjdk-11/settings-docker.xml /usr/share/maven/ref/

# set workdir
RUN mkdir -p /opt/code/localstack
WORKDIR /opt/code/localstack/

# install npm dependencies
ADD localstack/package.json localstack/package.json
RUN cd localstack && npm install && rm -rf /root/.npm;

# install supervisor
RUN pip3 install supervisor

# init environment and cache some dependencies
ARG DYNAMODB_ZIP_URL=https://s3-us-west-2.amazonaws.com/dynamodb-local/dynamodb_local_latest.zip
RUN mkdir -p /opt/code/localstack/localstack/infra && \
    mkdir -p /opt/code/localstack/localstack/infra/dynamodb && \
      curl -L -o /tmp/localstack.ddb.zip ${DYNAMODB_ZIP_URL} && \
      (cd localstack/infra/dynamodb && unzip -q /tmp/localstack.ddb.zip && rm /tmp/localstack.ddb.zip) && \
    curl -L -o /tmp/elasticmq-server.jar \
        https://s3-eu-west-1.amazonaws.com/softwaremill-public/elasticmq-server-1.1.0.jar

# final fixes
RUN which python || ln -s /usr/bin/python3 /usr/bin/python

# install basic tools to final image
RUN pip install awscli-local requests --upgrade

# install supervisor config file and entrypoint script
ADD bin/supervisord.conf /etc/supervisord.conf
ADD bin/docker-entrypoint.sh /usr/local/bin/

# expose default environment
# Set edge bind host so localstack can be reached by other containers
# set library path and default LocalStack hostname
ENV MAVEN_CONFIG=/opt/code/localstack \
    LD_LIBRARY_PATH=/usr/lib/jvm/java-11/lib:/usr/lib/jvm/java-11/lib/server \
    USER=localstack \
    PYTHONUNBUFFERED=1 \
    EDGE_BIND_HOST=0.0.0.0 \
    LOCALSTACK_HOSTNAME=localhost

RUN mkdir /root/.serverless; chmod -R 777 /root/.serverless

# add trusted CA certificates to the cert store
RUN curl https://letsencrypt.org/certs/letsencryptauthorityx3.pem.txt >> /etc/ssl/certs/ca-certificates.crt

# expose edge service, ElasticSearch & debugpy ports
EXPOSE 4566 4571 5678

# define command at startup
ENTRYPOINT ["docker-entrypoint.sh"]


FROM base as base-arm64
# Work around crashes in Kenesis with error -11
# https://github.com/localstack/localstack/issues/4358
ENV KINESIS_PROVIDER=kinesalite


FROM base as base-amd64
ENV KINESIS_PROVIDER=kinesis-mock


FROM base-${TARGETARCH} as builder

# Install build dependencies to base
RUN apt-get update && apt-get install -y autoconf automake cmake libsasl2-dev \
        g++ gcc libffi-dev libkrb5-dev libssl-dev \
        postgresql-server-dev-11 libpq-dev

# installing terraform temporary - removed in the final docker image
ARG TERRAFORM_ZIP_URL=https://releases.hashicorp.com/terraform/0.15.5/terraform_0.15.5_linux_${TARGETARCH}.zip
RUN mkdir -p /opt/terraform && \
    curl -L -o /opt/terraform/terraform.zip ${TERRAFORM_ZIP_URL} && \
    (cd /opt/terraform && unzip -q /opt/terraform/terraform.zip && rm /opt/terraform/terraform.zip)
ENV PATH="${PATH}:/opt/terraform"

ADD requirements.txt .
RUN (pip3 install --upgrade pip) && \
    (test `which virtualenv` || pip3 install virtualenv || sudo pip3 install virtualenv) && \
    (virtualenv .venv && source .venv/bin/activate && \
        pip3 install --upgrade pip && \
        pip3 install Cython && \
        export CPATH=/usr/include/python3.9 && \
        pip3 install -r requirements.txt && \
        rm -rf .venv) || exit 1

# install libs that require dependencies that are cleaned up below (e.g., gcc)
RUN (virtualenv .venv && source .venv/bin/activate && pip install 'cryptography<3.4' 'uamqp>=1.2.14' 'coverage[toml]>=5.5')

# install basic tools for build
RUN pip install awscli --upgrade

# upgrade python build tools
RUN (virtualenv .venv && source .venv/bin/activate && pip install --upgrade pip wheel setuptools localstack-plugin-loader)

# add configuration and source files
ADD Makefile setup.py requirements.txt pyproject.toml ./
ADD localstack/ localstack/
ADD bin/localstack bin/localstack
# necessary for running pip install -e
ADD bin/localstack.bat bin/localstack.bat

# install dependencies to run the localstack runtime and save which ones were installed
RUN make install-runtime
RUN make freeze > requirements-runtime.txt

# initialize installation (downloads remaining dependencies)
ADD localstack/infra/stepfunctions localstack/infra/stepfunctions
RUN make init

# clean up and prepare for squashing the image
RUN pip uninstall -y awscli boto3 botocore localstack_client idna s3transfer
RUN rm -rf .venv/lib/python3.*/site-packages/cfnlint
RUN (virtualenv .venv && source .venv/bin/activate && pip cache purge)
# RUN rm -rf /tmp/* /root/.cache /opt/yarn-* /root/.npm/*cache

FROM base-${TARGETARCH} as light

# Install runtime dependences to base
RUN apt-get update && \
        # Install dependencies to get Docker
        apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release && \
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
        # Install Runtime Packages
        apt-get update && \
        apt-get install -y --no-install-recommends \
            # Install latest version of Docker-CLI
            docker-ce-cli \
            # Required for AWS CLI Help
            groff-base \
            iputils-ping \
            nss-passwords \
            postgresql \
            postgresql-client \
            postgresql-plpython3

# Copy in the build dependences
COPY --from=builder /opt/code/localstack /opt/code/localstack

RUN mkdir -p /tmp/localstack && \
    if [ -e /usr/bin/aws ]; then mv /usr/bin/aws /usr/bin/aws.bk; fi; ln -s /opt/code/localstack/.venv/bin/aws /usr/bin/aws

# set up PYTHONPATH (after global pip packages are removed above), accommodating different install paths
ENV PYTHONPATH=/opt/code/localstack/.venv/lib/python3.9/site-packages:/opt/code/localstack/.venv/lib/python3.8/site-packages:/opt/code/localstack/.venv/lib/python3.7/site-packages
RUN which awslocal

# fix some permissions and create local user
RUN mkdir -p /.npm && \
    chmod 777 . && \
    chmod 755 /root && \
    chmod -R 777 /.npm && \
    chmod -R 777 /tmp/localstack && \
    useradd -ms /bin/bash localstack && \
    # chown -R localstack:localstack . /tmp/localstack && \
    ln -s `pwd` /tmp/localstack_install_dir



FROM light as full

# Install Elasticsearch
# https://github.com/pires/docker-elasticsearch/issues/56
ENV ES_TMPDIR /tmp

ENV ES_BASE_DIR=localstack/infra/elasticsearch
ENV ES_JAVA_HOME /usr/lib/jvm/java-11
RUN TARGETARCH_SYNONYM=$([[ "$TARGETARCH" == "amd64" ]] && echo "x86_64" || echo "aarch64"); \
    curl -L -o /tmp/localstack.es.tar.gz \
        https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-7.7.0-linux-${TARGETARCH_SYNONYM}.tar.gz && \
    (cd localstack/infra/ && tar -xf /tmp/localstack.es.tar.gz && \
        mv elasticsearch* elasticsearch && rm /tmp/localstack.es.tar.gz) && \
    (cd $ES_BASE_DIR && \
        bin/elasticsearch-plugin install analysis-icu && \
        bin/elasticsearch-plugin install ingest-attachment --batch && \
        bin/elasticsearch-plugin install analysis-kuromoji && \
        bin/elasticsearch-plugin install mapper-murmur3 && \
        bin/elasticsearch-plugin install mapper-size && \
        bin/elasticsearch-plugin install analysis-phonetic && \
        bin/elasticsearch-plugin install analysis-smartcn && \
        bin/elasticsearch-plugin install analysis-stempel && \
        bin/elasticsearch-plugin install analysis-ukrainian) && \
    ( rm -rf $ES_BASE_DIR/jdk/ ) && \
    ( mkdir -p $ES_BASE_DIR/data && \
        mkdir -p $ES_BASE_DIR/logs && \
        chmod -R 777 $ES_BASE_DIR/config && \
        chmod -R 777 $ES_BASE_DIR/data && \
        chmod -R 777 $ES_BASE_DIR/logs)
