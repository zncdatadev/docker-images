#!/bin/sh
set -eu

image=${1:?Usage: test_keycloak_java.sh IMAGE [PLATFORM]}
platform=${2:-}
if [ -n "$platform" ]; then
    set -- --platform "$platform"
else
    set --
fi

docker run --rm --network none "$@" --entrypoint /bin/sh "$image" -ec '
    java -version 2>&1 | grep -q "version \"17\."
    javac -version 2>&1 | grep -q "^javac 17\."
    java17_home=/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)
    for tool in java javac keytool rmiregistry; do
        test "$(readlink -f "/usr/bin/$tool")" = "$java17_home/bin/$tool"
    done
    test "$(readlink -f /usr/bin/jexec)" = "$java17_home/lib/jexec"
    if ls -d /usr/lib/jvm/*11* >/dev/null 2>&1; then
        echo "Unexpected Java 11 installation" >&2
        exit 1
    fi
    printf "%s\n" "public class RuntimeCheck { public static void main(String[] args) { System.out.print(\"ok\"); } }" > /tmp/RuntimeCheck.java
    javac /tmp/RuntimeCheck.java
    test "$(java -cp /tmp RuntimeCheck)" = ok
    keytool -list -cacerts -storepass changeit 2>/dev/null | grep -q trustedCertEntry
    test -w /kubedoop/keycloak/bin/kcadm.sh
    test -w /kubedoop/keycloak/bin/kcreg.sh
    output=$(kcadm.sh help)
    case "$output" in *"Keycloak Admin CLI"*) ;; *) exit 1 ;; esac
    output=$(/kubedoop/keycloak/bin/kcadm.sh help)
    case "$output" in *"Keycloak Admin CLI"*) ;; *) exit 1 ;; esac
    output=$(kcreg.sh help)
    case "$output" in *"Keycloak Client Registration CLI"*) ;; *) exit 1 ;; esac

    # The upstream CLI scripts allow callers to override their Java runtime.
    output=$(JAVA=/bin/echo JAVA_HOME=/nonexistent kcadm.sh help)
    case "$output" in
        *org.keycloak.client.admin.cli.KcAdmMain*) ;;
        *) exit 1 ;;
    esac
    output=$(JAVA=/bin/echo JAVA_HOME=/nonexistent kcreg.sh help)
    case "$output" in
        *org.keycloak.client.registration.cli.KcRegMain*) ;;
        *) exit 1 ;;
    esac

    mkdir -p /tmp/keycloak-java-override/bin
    ln -s /bin/echo /tmp/keycloak-java-override/bin/java
    output=$(JAVA_HOME=/tmp/keycloak-java-override kcadm.sh help)
    case "$output" in
        *org.keycloak.client.admin.cli.KcAdmMain*) ;;
        *) exit 1 ;;
    esac
    output=$(JAVA_HOME=/tmp/keycloak-java-override kcreg.sh help)
    case "$output" in
        *org.keycloak.client.registration.cli.KcRegMain*) ;;
        *) exit 1 ;;
    esac
    echo "Keycloak CLI and Java selection checks passed"
'
