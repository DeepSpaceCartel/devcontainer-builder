Feature: Deploy the sandbox nginx chart

  Scenario: ...
    # This step vadidates Chart.yaml
    Given Helm Chart available at "sandbox/nginx":
      | KEY     | VALUE |
      | .name   | nginx |
    # This step builds command and checks exit code
    When I successfully run "helm upgrade --install sandbox-nginx sandbox/nginx" known as "<DeployCommand>" with:
      | OPTION              | VALUE            |
      | --namespace         | sandbox          |
      | --create-namespace  | true             |
      | --set               | replicaCount=2   |
    # helm list -n sandbox -o yaml      
    # - app_version: "1.27"
    #   chart: nginx-0.1.0
    #   name: sandbox-nginx
    #   namespace: sandbox
    #   revision: "1"
    #   status: deployed
    #   updated: 2026-09-07 00:51:56.00816413 +0000 UTC
    Then helm list for release "<DeployCommand>" is available in "30s" with:
      | KEY                 | CONDITION | VALUE         |
      | .app_version         | equal     | "1.27"        | 
      | .chart               | equal     | nginx-0.1.0   | 
      | .name                | equal     | sandbox-nginx | 
      | .namespace           | equal     | sandbox       | 
      | .revision            | equal     | "1"           | 
      | .status              | equal     | deployed      | 
      | .updated             | newer     | 1m            | 
    # helm status sandbox-nginx -n sandbox -o yaml
    # info:
    #   deleted: ""
    #   description: Install complete
    #   first_deployed: "2026-09-07T00:51:56.00816413Z"
    #   last_deployed: "2026-09-07T00:51:56.00816413Z"
    #   status: deployed
    # manifest: |
    # ...
    # name: sandbox-nginx
    # namespace: sandbox
    And helm status for release "<DeployCommand>" is available in "30s" with:
      | KEY                 | CONDITION | VALUE                                     |
      | .info.deleted        | equal     | ""                                        |
      | .info.description    | equal     | Install complete                          |
      | .info.first_deployed | newer     | 1m                                        |
      | .info.last_deployed  | newer     | 1m                                        |
      | .info.status         | equal     | deployed                                  |
      | .manifest            | contains  | # Source: nginx/templates/service.yaml    |
      | .manifest            | contains  | # Source: nginx/templates/deployment.yaml |      
      | .name                | equal     | sandbox-nginx                             |
      | .namespace           | equal     | sandbox                                   |
      | .version             | equal     | 1                                         |

# $ helm history sandbox-nginx -n sandbox -o yaml
# - app_version: "1.27"
#   chart: nginx-0.1.0
#   description: Install complete
#   revision: 1
#   status: deployed
#   updated: "2026-09-07T00:51:56.00816413Z"
    And helm history for release "<DeployCommand>" is available in "30s" with:
      | KEY         | CONDITION | VALUE             |
      | .[].app_version | equal     | "1.27"            |
      | .[].chart       | equal     | nginx-0.1.0       |
      | .[].description | equal     | Install complete  |
      | .[].description | equal     | Upgrade complete  |
      | .[].revision    | equal     | 1                 |
      | .[].status      | equal     | deployed          |
      | .[].updated     | newer     | 1m                |

    # $ helm get values sandbox-nginx -n sandbox -o yaml
    # replicaCount: 2
    And "helm get values <DeployCommand> -o yaml" has:
      | RESOURCE  | CONDITION | VALUE           |
      | EXIT_CODE | equal     | 0               |
      | STDOUT    | contains  | replicaCount: 2 |

    # $ helm get manifest sandbox-nginx -n sandbox
    And "helm get manifest <DeployCommand>" has:
      | RESOURCE  | CONDITION | VALUE |
      | EXIT_CODE | equal     | 0     |
      | STDOUT    | contains  | # Source: nginx/templates/service.yaml    |
      | STDOUT    | contains  | # Source: nginx/templates/deployment.yaml |

    And "helm get notes <DeployCommand>" has:
      | RESOURCE  | CONDITION | VALUE                                                           |
      | EXIT_CODE | equal     | 0                                                                |
      | STDOUT    | contains  | NOTES:                                                          |
      | STDOUT    | contains  | kubectl port-forward -n sandbox svc/sandbox-nginx-nginx 8080:80 |
      | STDOUT    | contains  | curl http://localhost:8080/                                     |

    # $ helm test sandbox-nginx -n sandbox
    # NOTE: all spaces in output are replaced with a single space to make it easier to match in tests
    And "helm test <DeployCommand>" has:
      | RESOURCE  | CONDITION | VALUE                                           |
      | EXIT_CODE | equal     | 0                                               |
      | STDOUT    | contains  | TEST SUITE: sandbox-nginx-nginx-test-connection |
      | STDOUT    | contains  | Phase: Succeeded                                |