FROM alpine:3.7

# get this by:
# curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt
ARG CLIVERSION=v1.10.5
ARG YQVERSION=2.0.1

# need git, jq, yq, some binaries and kubectl
RUN apk --update add git curl gettext jq

RUN curl -o /usr/local/bin/kubectl -LO https://storage.googleapis.com/kubernetes-release/release/${CLIVERSION}/bin/linux/amd64/kubectl
RUN chmod +x /usr/local/bin/kubectl

RUN curl -o /usr/local/bin/yq -LO https://github.com/mikefarah/yq/releases/download/${YQVERSION}/yq_linux_amd64
RUN chmod +x /usr/local/bin/yq


ADD entrypoint.sh /usr/local/bin/entrypoint

CMD ["/usr/local/bin/entrypoint"]
