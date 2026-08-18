@echo off
rem Fake Keil UV4.exe for CI/tests (no license needed). Verifies command
rem construction + execution + log capture path.
echo FAKE_BACKEND_OK UV4 -b %*
exit /b 0