-- Confirm where you are (rough equivalent to \conninfo)
SELECT CURRENT_USER(), USER(), @@hostname, @@port, DATABASE();

-- (Optional) Create/use the demo database
CREATE DATABASE IF NOT EXISTS demo_db;
USE demo_db;

-- 1) IAM-auth CDC user (no password; IAM token is used at connect time)
-- AWS docs: Aurora MySQL IAM users use AWSAuthenticationPlugin. :contentReference[oaicite:1]{index=1}
CREATE USER IF NOT EXISTS 'iam_demo_user'@'%' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS';

-- 2) Grants for CDC via binlog
-- AWS docs for binlog replication mention REPLICATION CLIENT + REPLICATION SLAVE. :contentReference[oaicite:2]{index=2}
-- In practice, CDC readers also need SELECT (at least on the tables you replicate).
GRANT SELECT ON demo_db.* TO 'iam_demo_user'@'%';
GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'iam_demo_user'@'%';


-- 3) Create a basic table to replicate
CREATE TABLE IF NOT EXISTS iamuser_test (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

  local_time VARCHAR(32) NOT NULL
    DEFAULT (DATE_FORMAT(NOW(), '%Y-%m-%d %H:%i:%s'))
);
INSERT INTO iamuser_test VALUES ();

---- 4) Optional: a classic username/password user too (if you want both auth methods live)
--CREATE USER IF NOT EXISTS 'demo_pw_user'@'%' IDENTIFIED BY 'Use2demo!';
--GRANT SELECT ON demo_db.* TO 'demo_pw_user'@'%';

FLUSH PRIVILEGES;

