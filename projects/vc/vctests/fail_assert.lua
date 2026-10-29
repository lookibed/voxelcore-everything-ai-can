-- lab vctest negative smoke: a failing assertion must give a non-zero exit code (verdict failed).
print("[vctest] fail_assert: about to fail")
assert(1 == 2, "lab vctest: intentional failure")
