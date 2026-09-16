*** Settings ***
Library    SSHLibrary

*** Variables ***
${CLUSTER_USER}     admin
${CLUSTER_PASSWORD}    Nethesis,1234
${TEST_HOST}    sam.ns8-ci.test

*** Test Cases ***
Check if ssh-access-manager is installed correctly
    ${output}  ${rc} =    Execute Command    add-module ${IMAGE_URL} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Check if ssh-access-manager can be configured
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${TEST_HOST}","lets_encrypt":false}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Check if ssh-access-manager configuration reads back
    ${output}  ${rc} =    Execute Command    api-cli run module/${module_id}/get-configuration --data '{}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    ${config} =    Evaluate    json.loads('''${output}''')    modules=json
    Should Be Equal    ${config}[host]    ${TEST_HOST}

Check if the ssh-access-manager virtualhost answers
    Wait Until Keyword Succeeds    180s    10s    ssh-access-manager answers behind Traefik

Check if the database dump is consistent
    # state-include.conf lists state/sam.pg_dump: bin/module-dump-state takes a
    # live dump, because the volume copy alone would restore inconsistent
    ${rc} =    Execute Command    runagent -m ${module_id} module-dump-state
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    ${output}  ${rc} =    Execute Command
    ...    runagent -m ${module_id} bash -c 'file -b $AGENT_STATE_DIR/sam.pg_dump; wc -c < $AGENT_STATE_DIR/sam.pg_dump'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Contain    ${output}    PostgreSQL custom database dump

Check if a password can be reset
    # bin/reset-password is how an operator recovers an account, and nothing
    # exercised it
    ${output}  ${rc} =    Execute Command
    ...    runagent -m ${module_id} reset-password --username admin --password 'Nethesis,1234'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0

Check if the services are running
    ${rc} =    Execute Command
    ...    runagent -m ${module_id} systemctl --user is-active sam.service sam-app.service
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Check if a configuration without the host is refused
    # The agent exits 10 on a JSON Schema input validation failure
    ${errors}  ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"lets_encrypt":false}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  10
    # A missing required field is reported on the whole object, and the field
    # name goes to stderr, which Execute Command does not return here
    Should Contain    ${errors}    (root)_required

Take screenshots of the module pages
    [Documentation]    Capture what cluster-admin shows, for the software center
    ...                entry. Tagged ui: the shared runner skips it unless
    ...                RUN_UI_TESTS is true, since it needs a browser.
    [Tags]    ui
    Import Library    Browser
    New Browser    chromium    headless=True
    New Context    ignoreHTTPSErrors=True    viewport={'width': 1280, 'height': 900}
    Login to cluster-admin
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}
    Wait For Elements State    iframe >>> h2 >> text="Status"    visible    timeout=10s
    # The page fills itself from several tasks: let them land
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/1._Status.png
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}?page=settings
    Wait For Elements State    iframe >>> h2 >> text="Settings"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/2._Settings.png
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}?page=about
    Wait For Elements State    iframe >>> h2 >> text="About"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/3._About.png
    Close Browser

Check if ssh-access-manager is removed correctly
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

*** Keywords ***
Login to cluster-admin
    New Page    https://${NODE_ADDR}/cluster-admin/
    Fill Text    text="Username"    ${CLUSTER_USER}
    Click    button >> text="Continue"
    Fill Text    text="Password"    ${CLUSTER_PASSWORD}
    Click    button >> text="Log in"
    Wait For Elements State    css=#main-content    visible    timeout=10s

ssh-access-manager answers behind Traefik
    # configure_traefik hardcodes http2https, so the route only answers on TLS,
    # with a self-signed certificate the node generated for itself.
    #
    # Deliberately weak: this asserts a non-empty body rather than a string,
    # because a status check alone passes on an empty 302 and I could not
    # verify what a configured instance serves. Tighten it with a real marker
    # once known, the way ns8-pihole greps <form id="loginform">.
    ${output}  ${rc} =    Execute Command
    ...    curl -fsSk -H 'Host: ${TEST_HOST}' https://127.0.0.1/
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Not Be Empty    ${output}
