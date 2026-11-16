# Bytecode is arch-independent: build natively once, only the runtime stage is per-platform.
FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src src
RUN mvn -q package

FROM eclipse-temurin:21-jre
COPY --from=build /src/target/pingpong-1.0.jar /app/app.jar
COPY --from=build /src/target/lib /app/lib
ENTRYPOINT ["java", "-cp", "/app/app.jar:/app/lib/*", "demo.PingPong"]
