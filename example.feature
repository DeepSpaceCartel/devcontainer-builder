@feature-tag
Feature: <Feature name>
As a <role>
I want <capability>
So that <business value>

This is a free-form feature description.
It can span multiple lines and provides additional context.

Background:
Given <common precondition>
And <another common precondition>
But <common exception or exclusion>

Rule: <Business rule name>

```
This rule can have its own description.

Background:
  Given <rule-specific common precondition>

@scenario-tag
Scenario: <Scenario name>
  Given <initial condition>
  And <additional condition>
  When <action>
  And <additional action>
  Then <expected outcome>
  And <additional outcome>
  But <negative outcome>

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
```

Rule: <Another business rule>

```
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
```

Rule: <Rule with complex examples>

```
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
```
