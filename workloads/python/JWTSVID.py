from spiffe import JwtSource

def Session(jwt_source: JwtSource, jwt_audience: str):
    # Get an JWT token with the provided audience.
    jwt_svid = jwt_source.fetch_svid(audience={jwt_audience})
    print(f"Fetched JWT SVID with audience {jwt_audience}:\n {jwt_svid.token}\n")

Session(JwtSource(), "defakto.security")
