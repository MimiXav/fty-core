test_it
api_get_json /topology/power?filter_group=5088 >&5
print_result $?
