

Name:             devcontainer-builder-devcontainer-builder-6fc5bf9df6-wmxv9
Namespace:        devcontainer-builder-technopriest-default
Priority:         0
Service Account:  devcontainer-builder-devcontainer-builder
Node:             rts-dev-autoscaler-456f8d21b4a2c666/10.0.95.129
Start Time:       Mon, 07 Sep 2026 00:08:56 +0000
Labels:           app.kubernetes.io/instance=devcontainer-builder
                  app.kubernetes.io/managed-by=Helm
                  app.kubernetes.io/name=devcontainer-builder
                  helm.sh/chart=devcontainer-builder-0.1.0
                  pod-template-hash=6fc5bf9df6
Annotations:      checksum/git-credentials: 4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945
                  checksum/registry-auth: ec21c035eccb78eb5ca20ec95628eb351633621e09a130ac8d7e663714d40c7a
                  checksum/registry-mapping: 4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945
Status:           Running
IP:               10.0.129.228
IPs:
  IP:           10.0.129.228
Controlled By:  ReplicaSet/devcontainer-builder-devcontainer-builder-6fc5bf9df6
Containers:
  devcontainer-builder:
    Container ID:   containerd://0d2c8616cba2e77407a6b165a4b2be493b29d77c0b856fb0b42aa625048dc7fc
    Image:          ghcr.io/alexanderilyin/devcontainer-builder-test:test
    Image ID:       ghcr.io/alexanderilyin/devcontainer-builder-test@sha256:1687afb129b55122cf3a73280fff682bd5234016a4035f0d2b96ace4299bae39
    Port:           8080/TCP (http)
    Host Port:      0/TCP (http)
    State:          Running
      Started:      Mon, 07 Sep 2026 00:08:58 +0000
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     1
      memory:  1Gi
    Requests:
      cpu:      250m
      memory:   256Mi
    Liveness:   http-get http://:http/health/live delay=5s timeout=1s period=15s #success=1 #failure=3
    Readiness:  http-get http://:http/health/ready delay=2s timeout=1s period=5s #success=1 #failure=3
    Environment:
      PORT:                          8080
      BUILDKIT_ENDPOINT:             tcp://test-buildkit-buildkit-service.devcontainer-builder-technopriest-default.svc.cluster.local:1234
      DOCKER_CONFIG:                 /home/builder/.docker
      GIT_CREDENTIALS_CONFIG_PATH:   /home/builder/.config/git-credentials.json
      REGISTRY_MAPPING_CONFIG_PATH:  /home/builder/.config/registry-mapping.json
      SSH_HOST_KEY_POLICY:           tofu
    Mounts:
      /home/builder/.config/git-credentials.json from git-credentials (ro,path="git-credentials.json")
      /home/builder/.config/registry-mapping.json from registry-mapping (ro,path="registry-mapping.json")
      /home/builder/.docker from registry-auth (ro)
      /tmp from scratch (rw)
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-jntgx (ro)
Conditions:
  Type                        Status
  PodReadyToStartContainers   True 
  Initialized                 True 
  Ready                       True 
  ContainersReady             True 
  PodScheduled                True 
Volumes:
  registry-auth:
    Type:        Secret (a volume populated by a Secret)
    SecretName:  devcontainer-builder-devcontainer-builder-registry-auth
    Optional:    false
  git-credentials:
    Type:        Secret (a volume populated by a Secret)
    SecretName:  devcontainer-builder-devcontainer-builder-git-credentials
    Optional:    false
  registry-mapping:
    Type:      ConfigMap (a volume populated by a ConfigMap)
    Name:      devcontainer-builder-devcontainer-builder-registry-mapping
    Optional:  false
  scratch:
    Type:       EmptyDir (a temporary directory that shares a pod's lifetime)
    Medium:     
    SizeLimit:  5Gi
  kube-api-access-jntgx:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    Optional:                false
    DownwardAPI:             true
QoS Class:                   Burstable
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  79s   default-scheduler  Successfully assigned devcontainer-builder-technopriest-default/devcontainer-builder-devcontainer-builder-6fc5bf9df6-wmxv9 to rts-dev-autoscaler-456f8d21b4a2c666
  Normal  Pulling    79s   kubelet            spec.containers{devcontainer-builder}: Pulling image "ghcr.io/alexanderilyin/devcontainer-builder-test:test"
  Normal  Pulled     77s   kubelet            spec.containers{devcontainer-builder}: Successfully pulled image "ghcr.io/alexanderilyin/devcontainer-builder-test:test" in 1.169s (1.169s including waiting). Image size: 167595234 bytes.
  Normal  Created    77s   kubelet            spec.containers{devcontainer-builder}: Created container: devcontainer-builder
  Normal  Started    77s   kubelet            spec.containers{devcontainer-builder}: Started container devcontainer-builder
