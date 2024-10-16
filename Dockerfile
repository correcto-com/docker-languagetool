ARG LANGUAGETOOL_VERSION=6.5

FROM debian:bookworm as build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y \
    && apt-get install -y \
    locales \
    bash \
    libgomp1 \
    openjdk-17-jdk-headless \
    git \
    maven \
    unzip \
    xmlstarlet \

    # packages required for arm64-workaround
    build-essential \
    cmake \
    mercurial \
    texlive \
    wget \
    zip \
    && apt-get clean

RUN sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=en_US.UTF-8
ENV LANG en_US.UTF-8

ARG LANGUAGETOOL_VERSION
RUN git clone https://github.com/languagetool-org/languagetool.git --depth 1 -b v${LANGUAGETOOL_VERSION}
WORKDIR /languagetool
RUN ["mvn", "--projects", "languagetool-standalone", "--also-make", "package", "-DskipTests", "--quiet"]
RUN LANGUAGETOOL_DIST_VERSION=$(xmlstarlet sel -N "x=http://maven.apache.org/POM/4.0.0" -t -v "//x:project/x:properties/x:revision" pom.xml) && unzip /languagetool/languagetool-standalone/target/LanguageTool-${LANGUAGETOOL_DIST_VERSION}.zip -d /dist
RUN LANGUAGETOOL_DIST_FOLDER=$(find /dist/ -name 'LanguageTool-*') && mv $LANGUAGETOOL_DIST_FOLDER /dist/LanguageTool

# Execute workarounds for ARM64 architectures.
# https://github.com/languagetool-org/languagetool/issues/4543
WORKDIR /
COPY arm64-workaround/bridj.sh arm64-workaround/bridj.sh
RUN chmod +x arm64-workaround/bridj.sh
RUN bash -c "arm64-workaround/bridj.sh"

COPY arm64-workaround/hunspell.sh arm64-workaround/hunspell.sh
RUN chmod +x arm64-workaround/hunspell.sh
RUN bash -c "arm64-workaround/hunspell.sh"

WORKDIR /languagetool

# Note: When changing the base image, verify that the hunspell.sh workaround is
# downloading the matching version of `libhunspell`. The URL may need to change.
FROM alpine:3.19.0

RUN apk add --no-cache \
    && apk --no-cache add --virtual .builddeps \
    build-base -dev \
    bash \
    curl \
    libc6-compat \
    libstdc++ \
    openjdk11-jre-headless \
    gcc \
    g++ \
    fasttext-dev \
    fasttext-libs \
    wget \
    git \
    unzip \
    bash \
    libstdc++ \
    && rm -rf /var/cache/apk/*

RUN addgroup -S languagetool && adduser -S languagetool -G languagetool

COPY --chown=languagetool --from=build /dist .

WORKDIR /LanguageTool

RUN mkdir /nonexistent && touch /nonexistent/.languagetool.cfg

COPY --chown=languagetool start.sh start.sh

COPY --chown=languagetool config.properties config.properties

FROM alpine:3.16.2 as build
RUN apk add git build-base --no-cache
RUN git clone https://github.com/facebookresearch/fastText.git \
    && cd fastText \
    && make

RUN wget https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.bin

FROM erikvl87/languagetool:latest

WORKDIR /LanguageTool

COPY --chown=languagetool --from=build /fastText/fasttext .
COPY --chown=languagetool --from=build lid.176.bin .

USER languagetool

ENV langtool_maxCheckThreads=10
ENV langtool_cacheSize=512000
ENV langtool_fasttextModel=/LanguageTool/lid.176.bin
ENV langtool_fasttextBinary=/LanguageTool/fasttext
ENV Java_Xms=1g
ENV Java_Xmx=2g

HEALTHCHECK --timeout=10s --start-period=5s CMD curl --fail --data "language=en-US&text=a simple test" http://localhost:8010/v2/check || exit 1

CMD [ "bash", "start.sh" ]

EXPOSE 8010
