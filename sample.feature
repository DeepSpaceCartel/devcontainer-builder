# Hey I like Gherking language with all it's Background / When / Then but it seems that I'm facing some limitations with my workflow. I'm basically testing e2e deployments to k8s and it feels like main challenge is that cucumber implementation is synchronoius / sequentional but I think I need something more flexable... for example I'd like to fire and forget helm install for example "Given I deploy helm chart "chart-name"" which will just run "helm install ..." in background and after that I want "Then container has "Scheduled" event 

@feature-tag
Feature: Deployment Pipeline for MicroserviceName
As a DevOps engineer
I want to deploy MicroserviceName through an automated deployment pipeline
So that deployments are repeatable, reliable, and require minimal manual intervention

# Background:
# Given <common precondition>
# And <another common precondition>
# But <common exception or exclusion>

Rule: All containers in successful deployment must be Running and healthy
  This rule can have its own description.
  # Background:
  #   Given <rule-specific common precondition>
  @scenario-tag
  Scenario: Deploying MicroserviceName with default Values
    Given helm chart "microservice-name" is available at "./charts/microservice-name"
    And values for "microservice-name" helm chart are:
      | key   | value |
      | replicaCount | 3 |
      | image.repository | myregistry/microservice-name |
      | image.tag | latest |
    When I deploy "microservice-name" helm chart
    Then namespace "microservice-namespace" should exist in "10s"
     And deployment "microservice-name" in namespace "microservice-namespace" should have 3 replicas in "30s"
    And all pods in deployment "microservice-name" in namespace "microservice-namespace" should be Running and healthy in "60s"
    And service "microservice-name" in namespace "microservice-namespace" should be available in "30s"
    And ingress "microservice-name" in namespace "microservice-namespace" should be available in "30s"
    And logs for pod "microservice-name" in namespace "microservice-namespace" should not contain "Error" in "30s"


    When I deploy "microservice-name" using the helm chart
    Then all containers in the deployment should be Running and healthy
#    When <action>
#    And <additional action>
#    Then <expected outcome>
#    And <additional outcome>
#    But <negative outcome>

  Scenario: Using a data table
    Given the following users exist:
      | name  | email             | role  |
      | Alice | alice@example.com | admin |
      | Bob   | bob@example.com   | user  |
    When I request the users
    Then the response contains:
      | name  | role  |
      | Alice | admin |
      | Bob   | user  |

  Scenario: Using a DocString
    Given the following request body:
      """
      {
        "name": "Alice",
        "email": "alice@example.com"
      }
      """
    When I submit the request
    Then the response body is:
      """
      {
        "status": "created"
      }
      """

  Scenario: Using an alternative step keyword
    * the system is configured
    * the database is available
    * the API is running
    * I make a request
    * the response is successful

Rule: <Another business rule> CrashLoopBackOffΔ Error

  @outline-tag
  Scenario Outline: <Scenario template name>
    Given a user with role "<role>"
    When the user performs "<action>"
    Then the result should be "<result>"

    Examples: Standard cases
      | role  | action | result  |
      | admin | read   | allowed |
      | admin | write  | allowed |
      | user  | read   | allowed |
      | user  | write  | denied  |

    @negative
    Examples: Edge cases
      | role     | action | result |
      | guest    | write  | denied |
      | disabled | read   | denied |

Rule: <Rule with complex examples>

Scenario Outline: <Description>
  Given the input is <input>
  When I calculate the result
  Then the result is <result>

  Examples:
    | input | result |
    | 0     | 0      |
    | 1     | 1      |
    | 10    | 100    |
    | -1    | 1      |
