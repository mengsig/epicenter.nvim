class BaseCase:
    def setup_case(self):
        return None


class FlowCase(BaseCase):
    def test_dispatch(self):
        return dispatch("GET", "/")
