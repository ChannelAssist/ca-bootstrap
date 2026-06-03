package ghauth

import "testing"

func TestStatus_MockAuthed(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:octocat")
	user, authed, err := Status()
	if err != nil || !authed || user != "octocat" {
		t.Errorf("Status() = %q,%v,%v; want octocat,true,nil", user, authed, err)
	}
}

func TestStatus_MockUnauthed(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "unauthed")
	user, authed, err := Status()
	if err != nil || authed || user != "" {
		t.Errorf("Status() = %q,%v,%v; want \"\",false,nil", user, authed, err)
	}
}

func TestStatus_MockGhMissing(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "gh-missing")
	_, authed, err := Status()
	if authed || err == nil {
		t.Errorf("Status() with gh-missing = authed=%v err=%v; want false + error", authed, err)
	}
}

func TestLogin_MockSuccessAndFail(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "unauthed")
	if err := Login("https"); err != nil {
		t.Errorf("Login mock success: unexpected err %v", err)
	}
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "login-fail")
	if err := Login("https"); err == nil {
		t.Error("Login mock fail: expected error")
	}
}

func TestLogout_MockNoop(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:x")
	if err := Logout(); err != nil {
		t.Errorf("Logout mock: unexpected err %v", err)
	}
}
