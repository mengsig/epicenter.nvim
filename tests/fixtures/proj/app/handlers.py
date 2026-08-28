class RequestHandler:
    def handle_request(self, method, path):
        return dispatch(method, path)

    def close(self):
        return None


def dispatch(method, path):
    return (method, path)
