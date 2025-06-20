import streamlit as st
import subprocess
import sys
import os
import yaml
import tempfile
import re
import time

# Assuming examples/run_vision_discussion.py is in the examples directory
RUN_SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "examples", "run_vision_discussion.py")

st.title("Multi-AI Orchestrator")

st.write("Configure and run AI model conversations using run_vision_discussion.py.")

# Model Selection (using placeholder options for now)
# In a real app, you might fetch these from the script or a config
available_models = [
    "gemini-2.5-flash-preview",
    "gpt-4.1",
    "claude-3-7-sonnet",
    "ollama-llama3",
    "lmstudio-model",
]

human_model = st.selectbox("Select Human Model:", available_models, index=0)
ai_model = st.selectbox("Select AI Model:", available_models, index=1)

# Initial Prompt
initial_prompt = st.text_area("Enter Initial Prompt:", height=150)

# Optional Configuration File
config_file = st.file_uploader("Upload Configuration File (Optional):", type=["yaml", "json"])

# Number of Rounds
num_rounds = st.number_input("Number of Rounds:", min_value=1, value=2)

# Create columns for layout
col1, col2 = st.columns(2)

# Placeholder for raw terminal output
with col1:
    st.subheader("Terminal Output (Logs)")
    terminal_output_area = st.empty()
    raw_output_lines = []

# Placeholder for formatted conversation
with col2:
    st.subheader("Conversation")
    # Conversation will be displayed using st.chat_message

# Placeholder for flow chart
flow_chart_area = st.empty()

# Start Button
if st.button("Start Multi-AI Chat"):
    if not initial_prompt:
        st.warning("Please enter an initial prompt.")
    else:
        st.info("Starting AI Battle...")

        # Create a temporary config file
        temp_config_path = None
        try:
            if config_file is not None:
                # Use uploaded config file
                temp_config_file = tempfile.NamedTemporaryFile(delete=False, suffix=".yaml")
                temp_config_path = temp_config_file.name
                temp_config_file.write(config_file.getvalue())
                temp_config_file.close()
                st.success(f"Using uploaded config file: {config_file.name}")
            else:
                # Create a default config based on inputs
                default_config = {
                    "goal": initial_prompt,
                    "turns": num_rounds,
                    "models": {
                        "human_agent": {
                            "type": human_model,
                            "role": "human"
                        },
                        "ai_agent": {
                            "type": ai_model,
                            "role": "assistant"
                        }
                    },
                    "input_file": None, # Add logic here if you want to support file uploads
                    "input_files": None # Add logic here if you want to support multiple file uploads
                }
                temp_config_file = tempfile.NamedTemporaryFile(delete=False, suffix=".yaml")
                temp_config_path = temp_config_file.name
                with open(temp_config_path, "w") as f:
                    yaml.dump(default_config, f)
                st.info("Using generated default config.")

            # Define the command to run examples/run_vision_discussion.py
            command = [
                sys.executable, # Use the current Python executable
                RUN_SCRIPT_PATH,
                temp_config_path,
            ]

            terminal_output_area.text(f"Executing command: {' '.join(command)}")

            # Run the script and capture output in real-time
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

            # Display output in real-time and parse conversation turns
            conversation_history = []
            current_turn_content = ""
            current_turn_role = None

            # Use a container for the conversation area to update it dynamically
            conversation_container = col2.container()

            for line in process.stdout:
                raw_output_lines.append(line)
                terminal_output_area.text("".join(raw_output_lines))

                # Check for the start of a new conversation turn
                turn_start_match = re.match(r"(USER|ASSISTANT|SYSTEM): (.*)", line)

                if turn_start_match:
                    # If we were collecting content for a previous turn, save and display it
                    if current_turn_role is not None and current_turn_content:
                        conversation_history.append({"role": current_turn_role, "content": current_turn_content.strip()})
                        # Display the completed turn
                        with conversation_container:
                            role_display = current_turn_role.lower()
                            avatar = "🧑‍💻" if role_display == "user" else ("🤖" if role_display == "assistant" else "ℹ️")
                            with st.chat_message(role_display, avatar=avatar):
                                st.write(current_turn_content.strip())


                    # Start collecting content for the new turn
                    current_turn_role = turn_start_match.group(1).lower()
                    current_turn_content = turn_start_match.group(2).strip()
                elif current_turn_role is not None:
                    # Append line to the current turn's content if it's not a new turn start
                    current_turn_content += "\n" + line.strip()

            # After the loop, save and display the last collected turn
            if current_turn_role is not None and current_turn_content:
                 conversation_history.append({"role": current_turn_role, "content": current_turn_content.strip()})
                 # Display the completed turn
                 with conversation_container:
                     role_display = current_turn_role.lower()
                     avatar = "🧑‍💻" if role_display == "user" else ("🤖" if role_display == "assistant" else "ℹ️")
                     with st.chat_message(role_display, avatar=avatar):
                         st.write(current_turn_content.strip())


            # Wait for the process to finish
            process.wait()

            if process.returncode != 0:
                st.error(f"Script failed with return code {process.returncode}")
            else:
                st.success("AI Battle completed.")

            # Generate and display flow chart
            if conversation_history:
                flow_chart_area.subheader("Conversation Flow (Mermaid Syntax)")
                mermaid_syntax = "graph TD\n"
                for i, turn in enumerate(conversation_history):
                    node_id = f"turn{i}"
                    # Truncate content for node label
                    content_preview = turn['content'][:50].replace('"', "'") + "..." if len(turn['content']) > 50 else turn['content'].replace('"', "'")
                    mermaid_syntax += f"    {node_id}[{turn['role'].upper()}: {content_preview}]\n"
                    if i > 0:
                        prev_node_id = f"turn{i-1}"
                        mermaid_syntax += f"    {prev_node_id} --> {node_id}\n"

                flow_chart_area.code(mermaid_syntax, language="mermaid")
            else:
                flow_chart_area.info("No conversation history to generate flow chart.")


        except FileNotFoundError:
            st.error(f"Error: Script not found at {RUN_SCRIPT_PATH}")
        except Exception as e:
            st.error(f"An error occurred: {e}")
            import traceback
            st.error(traceback.format_exc())
        finally:
            # Clean up the temporary config file
            if temp_config_path and os.path.exists(temp_config_path):
                os.unlink(temp_config_path)
