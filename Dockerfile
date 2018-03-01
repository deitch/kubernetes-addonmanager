FROM alpine:3.6

# need git and kubectl
RUN apk --update add git curl gettext

RUN curl -o /usr/local/bin/kubectl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
RUN chmod +x /usr/local/bin/kubectl

ADD addons.sh /usr/local/bin

CMD ["/usr/local/bin/addons.sh"]
