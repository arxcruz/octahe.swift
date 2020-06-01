# Open Server Initiative

Configure servers using OCI compatible files.

## Configuration

The Open Server Inititive follows the [Dockerfile](https://docs.docker.com/engine/reference/builder)
reference, with one verb replacement.

#### TO

``` dockerfile
TO [--escalate=<path-to-binary>] <address>:<port>@<user>
```

The **TO** instruction initializes a new connection to a given target for subsequent instructions.
As such, a valid file must start with a **TO** instruction.

ARG is the only instruction that may precede **TO** in the file. See
[Understand how ARG and FROM interact](https://docs.docker.com/engine/reference/builder/#understand-how-arg-and-from-interact).

**TO** can appear multiple times within a single file to create multiple connections to different targets.

Every **TO** entry requires three parts **<address>:<port>@<user>**. The address can be an IP
address or FQDN. The port will always be an integer. The user should be the username required
to access the given server.

The optional --escalate flag can be used to specify the means of privledge escallation. This
option requires the binary needed to perform a privledge escallation. Privledge escallation
may require a password, if this is the case, provide the password via the CLI by including
the `--escalate-pw` flag. Any password provided will only exist during runtime as an ARG.

``` dockerfile
ARG  USER=access-user
TO   --escalate=/usr/bin/sudo 127.0.0.1:22@${USER}
RUN  dnf install -y curl
```

#### FROM

The **FROM** instruction will pull a container image, inspect the layers, and derive all compatible verbs which are then inserted into the execution process.

### Executing a deployment

``` shell
osi ~/Serverfile

Step 1/4 : TO 10.0.0.2:22@root
 ---> done
Step 2/4 : MAINTAINER kevin@cloudnull.com
 ---> done
Step 3/4 : RUN apk update && apk add socat && rm -r /var/cache/
 ---> done
Step 4/4 : CMD env | grep _TCP= | (sed 's/.*_PORT_\([0-9]*\)_TCP=tcp:\/\/\(.*\):\(.*\)/socat -t 100000000 TCP4-LISTEN:\1,fork,reuseaddr TCP4:\2:\3 \&/' && echo wait) | sh
 ---> done
Successfully deployed.
```

By default all servers listed in the **TO** verb will connect and execute the steps serially.
This can be changed by modifying the connection quota. If the quota is less than the total
number of targets, connections will be grouped by the given quota.

``` shell
osi --connection-quota=3 ~/Serverfile

Step 1/4 : TO [10.0.0.2:22@root,10.0.0.3:22@root,10.0.0.4:22@root],[10.0.0.5:22@root,10.0.0.6:22@root,10.0.0.7:22@root]
 ---> done
Step 2/4 : MAINTAINER kevin@cloudnull.com
 ---> done
Step 3/4 : RUN apk update && apk add socat && rm -r /var/cache/
 ---> done
Step 4/4 : CMD env | grep _TCP= | (sed 's/.*_PORT_\([0-9]*\)_TCP=tcp:\/\/\(.*\):\(.*\)/socat -t 100000000 TCP4-LISTEN:\1,fork,reuseaddr TCP4:\2:\3 \&/' && echo wait) | sh
 ---> done
Successfully deployed.
```

In the event of an execution failure, the failed targets will be taken out of the execution steps.

``` shell
osi --connection-quota=3 ~/Serverfile

Step 1/4 : TO [10.0.0.2:22@root,10.0.0.3:22@root,10.0.0.4:22@root],[10.0.0.5:22@root,10.0.0.6:22@root,10.0.0.7:22@root]
 ---> done
Step 2/4 : MAINTAINER kevin@cloudnull.com
 ---> done
Step 3/4 : RUN apk update && apk add socat && rm -r /var/cache/
 ---> degraded,
Step 4/4 : CMD env | grep _TCP= | (sed 's/.*_PORT_\([0-9]*\)_TCP=tcp:\/\/\(.*\):\(.*\)/socat -t 100000000 TCP4-LISTEN:\1,fork,reuseaddr TCP4:\2:\3 \&/' && echo wait) | sh
 ---> degraded
Deployed complete, but degraded.
Degrated hosts:
[-] 10.0.0.4:22@root - failed "Step 3/4"
[-] 10.0.0.6:22@root - failed "Step 4/4"
```

To rerun a failed execution on only the failed targets specify the targets on the CLI using the
`--target` flag.

``` shell
osi --connection-quota=3 --target="10.0.0.4:22@root,10.0.0.6:22@root" ~/Serverfile

Step 1/4 : TO [10.0.0.4:22@root,10.0.0.6:22@root]
 ---> done
Step 2/4 : MAINTAINER kevin@cloudnull.com
 ---> done
Step 3/4 : RUN apk update && apk add socat && rm -r /var/cache/
 ---> done
Step 4/4 : CMD env | grep _TCP= | (sed 's/.*_PORT_\([0-9]*\)_TCP=tcp:\/\/\(.*\):\(.*\)/socat -t 100000000 TCP4-LISTEN:\1,fork,reuseaddr TCP4:\2:\3 \&/' && echo wait) | sh
 ---> done
Successfully deployed.
```

### Special Case Verbs

The following verbs have special characteristics that will ensure a consistent experience.

#### ENTRYPOINT

The **ENTRYPOINT** verb will create a `oneshot` systemd service on the target. This will
result in the entrypoint commanded running on system start.

#### EXPOSE

The **EXPOSE** verb will create an IPTables rule for a given port and/or service mapping.

### Ignored Verbs

Because the following options have no effect on a server, they're ignored.

* HEALTHCHECK
* STOPSIGNAL
* ONBUILD
* VOLUME