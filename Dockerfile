# syntax=docker/dockerfile:1

# AdGuard Home 自建镜像：直接取上游官方 release 的可执行文件，只做重新打包。
# 基镜像、目录布局、EXPOSE、ENTRYPOINT/CMD 与上游 docker/build.Dockerfile 保持一致，
# 因此官方文档里的 docker run / compose 写法可以原样套用。
FROM alpine:3.23

ARG VERSION=dev
ARG VCS_REF=unknown

RUN apk --no-cache add ca-certificates libcap tzdata \
 && mkdir -p /opt/adguardhome/conf /opt/adguardhome/work \
 && chown -R nobody: /opt/adguardhome

# 由 workflow 下载 + sha256 校验后放进构建上下文
COPY --chmod=0755 AdGuardHome /opt/adguardhome/AdGuardHome

RUN setcap 'cap_net_bind_service=+eip' /opt/adguardhome/AdGuardHome

# 53    : TCP, UDP : DNS
# 67    :      UDP : DHCP (server)
# 68    :      UDP : DHCP (client)
# 80    : TCP      : HTTP (main)
# 443   : TCP, UDP : HTTPS, DNS-over-HTTPS (incl. HTTP/3), DNSCrypt (main)
# 853   : TCP, UDP : DNS-over-TLS, DNS-over-QUIC
# 3000  : TCP, UDP : HTTP(S) (alt, incl. HTTP/3)
# 5443  : TCP, UDP : DNSCrypt (alt)
# 6060  : TCP      : HTTP (pprof)
EXPOSE 53/tcp 53/udp \
	67/udp \
	68/udp \
	80/tcp \
	443/tcp 443/udp \
	853/tcp 853/udp \
	3000/tcp 3000/udp \
	5443/tcp 5443/udp \
	6060/tcp

WORKDIR /opt/adguardhome/work

ENTRYPOINT ["/opt/adguardhome/AdGuardHome"]
CMD ["--no-check-update", \
	"-c", "/opt/adguardhome/conf/AdGuardHome.yaml", \
	"-w", "/opt/adguardhome/work"]

LABEL \
	org.opencontainers.image.title="AdGuard Home" \
	org.opencontainers.image.description="Network-wide ads & trackers blocking DNS server (repack of upstream release binary)" \
	org.opencontainers.image.version="${VERSION}" \
	org.opencontainers.image.revision="${VCS_REF}" \
	org.opencontainers.image.source="https://github.com/AdguardTeam/AdGuardHome" \
	org.opencontainers.image.documentation="https://github.com/AdguardTeam/AdGuardHome/wiki/" \
	org.opencontainers.image.licenses="GPL-3.0"
