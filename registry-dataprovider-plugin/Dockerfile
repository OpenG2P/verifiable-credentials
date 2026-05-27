# Build the plugin JAR in a container (no local Java/Maven needed).
#
#   docker build --target artifact --output type=local,dest=./dist .
#   -> ./dist/registry-dataprovider-plugin.jar
#
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /work
COPY pom.xml .
RUN mvn -B dependency:go-offline
COPY src ./src
RUN mvn -B -DskipTests clean package

# Export just the JAR.
FROM scratch AS artifact
COPY --from=build /work/target/registry-dataprovider-plugin.jar /registry-dataprovider-plugin.jar
